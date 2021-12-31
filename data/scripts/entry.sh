#!/bin/bash

cleanup() {
    # When you run `docker stop` or any equivalent, a SIGTERM signal is sent to PID 1.
    # A process running as PID 1 inside a container is treated specially by Linux:
    # it ignores any signal with the default action. As a result, the process will
    # not terminate on SIGINT or SIGTERM unless it is coded to do so. Because of this,
    # I've defined behavior for when SIGINT and SIGTERM is received.
    if [ "$openvpn_child" ]; then
        echo "Stopping OpenVPN..."
        kill -TERM "$openvpn_child"
    fi

    sleep 1
    rm "$config_file_modified"
    echo "Exiting."
    exit 0
}

is_ip() {
    echo "$1" | grep -Eq "[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*"
}

# shellcheck disable=SC2153
if ! (echo "$VPN_LOG_LEVEL" | grep -Eq '^([1-9]|1[0-1])$'); then
    echo "WARNING: Invalid log level $VPN_LOG_LEVEL. Setting to default."
    vpn_log_level=3
else
    vpn_log_level=$VPN_LOG_LEVEL
fi

echo "
---- Running with the following variables ----
Kill switch: ${KILL_SWITCH:-off}
HTTP proxy: ${HTTP_PROXY:-off}
SOCKS proxy: ${SOCKS_PROXY:-off}
Proxy username secret: ${PROXY_PASSWORD_SECRET:-none}
Proxy password secret: ${PROXY_USERNAME_SECRET:-none}
Allowing subnets: ${SUBNETS:-none}
Using OpenVPN log level: $vpn_log_level
Listening on: ${LISTEN_ON:-none}"

if [ -n "$VPN_CONFIG_FILE" ]; then
    config_file_original="/data/vpn/$VPN_CONFIG_FILE"
else
    # Capture the filename of the first .conf file to use as the OpenVPN config.
    config_file_original=$(find /data/vpn -name "*.conf" 2> /dev/null | sort | head -1)
    if [ -z "$config_file_original" ]; then
        >&2 echo "ERROR: No configuration file found. Please check your mount and file permissions. Exiting."
        exit 1
    fi
fi
echo "Using configuration file: $config_file_original"

# Create a new configuration file to modify so the original is left untouched.
config_file_modified="${config_file_original}.modified"

echo "Creating $config_file_modified and making required changes to that file."
cp "$config_file_original" "$config_file_modified"

# These configuration file changes are required by Alpine.
sed -i \
    -e '/up /c up \/etc\/openvpn\/up.sh' \
    -e '/down /c down \/etc\/openvpn\/down.sh' \
    -e 's/^proto udp$/proto udp4/' \
    -e 's/^proto tcp$/proto tcp4/' \
    "$config_file_modified"

echo -e "Changes made.\n"

trap cleanup INT TERM

# NOTE: When testing with the kill switch enabled, don't forget to pass in the
# local subnet. It will save a lot of headache.
default_gateway=$(ip r | grep 'default via' | cut -d " " -f 3)
if [ "$KILL_SWITCH" = "on" ]; then
    local_subnet=$(ip r | grep -v 'default via' | grep eth0 | tail -n 1 | cut -d " " -f 1)

    echo "Creating VPN kill switch and local routes."

    echo "Allowing established and related connections..."
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    echo "Allowing loopback connections..."
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A OUTPUT -o lo -j ACCEPT

    echo "Allowing Docker network connections..."
    iptables -A INPUT -s "$local_subnet" -j ACCEPT
    iptables -A OUTPUT -d "$local_subnet" -j ACCEPT

    echo "Allowing specified subnets..."
    # for every specified subnet...
    for subnet in ${SUBNETS//,/ }; do
        # create a route to it and...
        ip route add "$subnet" via "$default_gateway" dev eth0
        # allow connections
        iptables -A INPUT -s "$subnet" -j ACCEPT
        iptables -A OUTPUT -d "$subnet" -j ACCEPT
    done

    echo "Allowing remote servers in configuration file..."
    remote_port=$(grep "port " "$config_file_modified" | cut -d " " -f 2)
    remote_proto=$(grep "proto " "$config_file_modified" | cut -d " " -f 2 | cut -c1-3)
    remotes=$(grep "remote " "$config_file_modified" | cut -d " " -f 2-4)

    echo "  Using:"
    echo "${remotes}" | while IFS= read -r line; do
        # strip any comments from line that could mess up cuts
        clean_line=${line%% #*}
        addr=$(echo "$clean_line" | cut -d " " -f 1)
        port=$(echo "$clean_line" | cut -s -d " " -f 2)
        proto=$(echo "$clean_line" | cut -s -d " " -f 3 | cut -c1-3)
        port=${port:-${remote_port:-1194}}
        proto=${proto:-${remote_proto:-udp}}

        if is_ip "$addr"; then
            echo "    IP: $addr PORT: $port PROTO: $proto"
            iptables -A OUTPUT -o eth0 -d "$addr" -p "${proto}" --dport "${port}" -j ACCEPT
        else
            for ip in $(dig -4 +short "$addr"); do
                echo "    $addr (IP: $ip PORT: $port PROTO: $proto)"
                iptables -A OUTPUT -o eth0 -d "$ip" -p "${proto}" --dport "${port}" -j ACCEPT
            done
        fi
    done

    echo "Allowing connections over VPN interface..."
    iptables -A INPUT -i tun0 -j ACCEPT
    iptables -A OUTPUT -o tun0 -j ACCEPT

    echo "Preventing anything else..."
    iptables -P INPUT DROP
    iptables -P OUTPUT DROP
    iptables -P FORWARD DROP

    echo -e "iptables rules created and routes configured.\n"
else
    echo -e "WARNING: VPN kill switch is disabled. Traffic will be allowed outside of the tunnel if the connection is lost.\n"
    echo "Creating routes to specified subnets..."
    for subnet in ${SUBNETS//,/ }; do
        ip route add "$subnet" via "$default_gateway" dev eth0
    done
    echo -e "Routes created.\n"
fi

if [ "$HTTP_PROXY" = "on" ]; then
    if [ "$PROXY_USERNAME" ]; then
        if [ "$PROXY_PASSWORD" ]; then
            echo "Configuring HTTP proxy authentication."
            echo -e "\nBasicAuth $PROXY_USERNAME $PROXY_PASSWORD" >> /data/tinyproxy.conf
        else
            echo "WARNING: Proxy username supplied without password. Starting HTTP proxy without credentials."
        fi
    elif [ -f "/run/secrets/$PROXY_USERNAME_SECRET" ]; then
        if [ -f "/run/secrets/$PROXY_PASSWORD_SECRET" ]; then
            echo "Configuring proxy authentication."
            echo -e "\nBasicAuth $(cat /run/secrets/$PROXY_USERNAME_SECRET) $(cat /run/secrets/$PROXY_PASSWORD_SECRET)" >> /data/tinyproxy.conf
        else
            echo "WARNING: Credentials secrets not read. Starting HTTP proxy without credentials."
        fi
    fi
    /data/scripts/tinyproxy_wrapper.sh &
fi

if [ "$SOCKS_PROXY" = "on" ]; then
    if [ "$LISTEN_ON" ]; then
            sed -i "s/internal: eth0/internal: $LISTEN_ON/" /data/sockd.conf    
    fi
    if [ "$PROXY_USERNAME" ]; then
        if [ "$PROXY_PASSWORD" ]; then
            echo "Configuring SOCKS proxy authentication."
            adduser -S -D -g "$PROXY_USERNAME" -H -h /dev/null "$PROXY_USERNAME"
            echo "$PROXY_USERNAME:$PROXY_PASSWORD" | chpasswd 2> /dev/null
            sed -i 's/socksmethod: none/socksmethod: username/' /data/sockd.conf
        else
            echo "WARNING: Proxy username supplied without password. Starting SOCKS proxy without credentials."
        fi
    elif [ -f "/run/secrets/$PROXY_USERNAME_SECRET" ]; then
        if [ -f "/run/secrets/$PROXY_PASSWORD_SECRET" ]; then
            echo "Configuring proxy authentication."
            adduser -S -D -g "$(cat /run/secrets/$PROXY_USERNAME_SECRET)" -H -h /dev/null "$(cat /run/secrets/$PROXY_USERNAME_SECRET)"
            echo "$(cat /run/secrets/$PROXY_USERNAME_SECRET):$(cat /run/secrets/$PROXY_PASSWORD_SECRET)" | chpasswd 2> /dev/null
            sed -i 's/socksmethod: none/socksmethod: username/' /data/sockd.conf
        else
            echo "WARNING: Credentials secrets not present. Starting SOCKS proxy without credentials."
        fi
    fi
    /data/scripts/dante_wrapper.sh &
fi

openvpn_args=(
    "--config" "$config_file_modified"
    "--auth-nocache"
    "--cd" "/data/vpn"
    "--pull-filter" "ignore" "ifconfig-ipv6"
    "--pull-filter" "ignore" "route-ipv6"
    "--script-security" "2"
    "--up-restart"
    "--verb" "$vpn_log_level"
)

if [ "$OPENVPN_AUTH_SECRET" ]; then 
    if [ -f "/run/secrets/$OPENVPN_AUTH_SECRET" ]; then
        echo "Configuring OpenVPN authentication."
        openvpn_args+=("--auth-user-pass" "/run/secrets/$OPENVPN_AUTH_SECRET")
    else
        echo "WARNING: OpenVPN credentials secrets not present."
    fi
fi

echo -e "Running OpenVPN client.\n"

openvpn "${openvpn_args[@]}" &
openvpn_child=$!

wait $openvpn_child
