#!/bin/bash

# Setup basic secure networking, such as iptable rules and sysctl parameters.
#
# /opt/opt/illinois/cloud-init/network.conf
#
#   ip_forward: 0 or 1 to enable or disable IP forwarding.
#   tcp_allow_ports: space delimited list of TCP ports to allow. Always
#       includes: SSH (22).
#   udp_allow_ports: space delimited list of UDP ports to allow.
#   allow_idms: system, root, or no to set allowed access to the AWS EC2
#       metadata endpoint.

set -e
ILLINOIS_MODULE=network

[[ -e /var/lib/illinois-network-init ]] && exit 0
. /etc/opt/illinois/cloud-init/init.sh

declare -a internal_subnets=()
[[ -e /etc/opt/illinois/cloud-init/network.conf ]] && . /etc/opt/illinois/cloud-init/network.conf

: ${ip_forward:=0}
: ${tcp_allow_ports:=""}
: ${udp_allow_ports:=""}
: ${allow_idms:=system}

illinois_init_status running

internal_subnet_routes () {
    if [[ ${#internal_subnets[@]} -eq 0 ]]; then
        illinois_log "internal_subnets is not set"
        return 0
    fi

    local interface=$(ip -json link show device-number-0 | jq -r 'first | .ifname')
    if [[ -z $interface ]]; then
        interface=$(ip -json link show device-number-0.0 | jq -r 'first | .ifname')
    fi
    if [[ -z $interface ]]; then
        illinois_log error "altname device-number-0 and device-number-0.0 lookup failed"
        return 1
    fi

    local unitdir="/etc/systemd/network/70-${interface}.network.d"
    [[ -e $unitdir ]] || mkdir -p "$unitdir"

    local unitfile_tmp=$(mktemp -t internal-subnets.XXXXXXXX.conf); tmpfiles+=("$unitfile_tmp")
    echo "# Generated file from ${internal_subnets}" > "$unitfile_tmp"

    for subnet in "${internal_subnets[@]}"; do
        local subnet_info="$(ip route show "$subnet")"
        if [[ -n $subnet_info ]]; then
            illinois_log "[$interface] subnet $subnet already has a route: $subnet_info"
            continue
        fi

        illinois_log "[$interface] adding subnet route: $subnet"
        echo -e "[Route]\nGateway=_dhcp4\nDestination=${subnet}\nMetric=100\n" >> "$unitfile_tmp"
    done

    local network_changed=n
    local unitfile="${unitdir}/illinois-internal-subnets.conf"
    if [[ ! -e $unitfile ]]; then
        cp "$unitfile_tmp" "$unitfile"
        chmod a+r "$unitfile"
        network_changed=y
    elif diff -q "$unitfile" "$unitfile_tmp"; then
        illinois_log "[$interface] no changes in routes"
    else
        local _diff_ec=$?
        if [[ $_diff_ec -eq 1 ]]; then
            illinois_log "[$interface] changes in routes"
            cp "$unitfile_tmp" "$unitfile"
            chmod a+r "$unitfile"
            network_changed=y
        else
            illinois_log error "[$interface] error comparing files"
            return $_diff_ec
        fi
    fi

    if [[ $network_changed = y ]]; then
        illinois_log "[$interface] Reloading networkd"
        networkctl reload
    fi
}

internal_subnet_routes

illinois_rpm_install iptables-nft iptables-services ipset ipset-service

for service in iptables ip6tables ipset; do
    if ! systemctl is-active $service &> /dev/null; then
        illinois_log "starting $service"
        systemctl enable --now $service
    fi
done

illinois_ipt_rule () {
    local ipt=$1
    local op=$2
    local chain=$3
    shift 3

    illinois_log "running: $ipt -t filter $op $chain $@"
    $ipt -t filter $op $chain "$@"
}
illinois_ip4_rule () { illinois_ipt_rule iptables "$@"; }
illinois_ip6_rule () { illinois_ipt_rule ip6tables "$@"; }

INPUT_TCP_ALLOW="22 $tcp_allow_ports"
INPUT_UDP_ALLOW="$udp_allow_ports"

iptables -t filter -N INPUT_illinois_allow
ip6tables -t filter -N INPUT_illinois_allow
for port in $INPUT_TCP_ALLOW; do
    illinois_ip4_rule -A INPUT_illinois_allow -p tcp --dport $port -j ACCEPT
    illinois_ip6_rule -A INPUT_illinois_allow -p tcp --dport $port -j ACCEPT
done
for port in $INPUT_UDP_ALLOW; do
    illinois_ip4_rule -A INPUT_illinois_allow -p udp --dport $port -j ACCEPT
    illinois_ip6_rule -A INPUT_illinois_allow -p udp --dport $port -j ACCEPT
done
illinois_ip4_rule -A INPUT_illinois_allow -p udp --dport 68 -j ACCEPT
illinois_ip6_rule -A INPUT_illinois_allow -p udp --dport 546 -d fe80::/64 -j ACCEPT

# Flush the tables first and then add our rules
for ipt in iptables ip6tables; do
    for chain in INPUT FORWARD OUTPUT; do
        illinois_log "flushing $ipt $chain"
        $ipt -t filter -F $chain
        illinois_log "setting $ipt $chain policy to DROP"
        $ipt -t filter -P $chain DROP
    done
done

for cmd in illinois_ip4_rule illinois_ip6_rule; do
    $cmd -A INPUT -i lo -j ACCEPT
    if [[ $cmd = illinois_ip4_rule ]]; then
        $cmd -A INPUT -s 127.0.0.0/8 -j DROP
        $cmd -A INPUT -p icmp -j ACCEPT
    else
        $cmd -A INPUT -s ::1 -j DROP
        $cmd -A INPUT -p icmpv6 -j ACCEPT
    fi
    $cmd -A INPUT -p tcp -m state --state ESTABLISHED,RELATED -j ACCEPT
    $cmd -A INPUT -p udp -m state --state ESTABLISHED,RELATED -j ACCEPT
    $cmd -A INPUT -m state --state NEW -j INPUT_illinois_allow

    $cmd -A OUTPUT -o lo -j ACCEPT

    if [[ $allow_idms = system ]]; then
        if [[ $cmd = illinois_ip4_rule ]]; then
            # block aws metadata endpoint (instance IAM Role) for non-system users
            $cmd -A OUTPUT -p tcp -d 169.254.169.254 -m owner --uid-owner 0-999 -j ACCEPT
            $cmd -A OUTPUT -p tcp -d 169.254.169.254 -j REJECT --reject-with icmp-admin-prohibited
        else
            # block aws metadata endpoint (instance IAM Role) for non-system users
            $cmd -A OUTPUT -p tcp -d fd00:ec2::254 -m owner --uid-owner 0-999 -j ACCEPT
            $cmd -A OUTPUT -p tcp -d fd00:ec2::254 -j REJECT --reject-with icmp6-adm-prohibited
        fi
    elif [[ $allow_idms = root ]]; then
        if [[ $cmd = illinois_ip4_rule ]]; then
            # block aws metadata endpoint (instance IAM Role) for non-system users
            $cmd -A OUTPUT -p tcp -d 169.254.169.254 -m owner --uid-owner 0 -j ACCEPT
            $cmd -A OUTPUT -p tcp -d 169.254.169.254 -j REJECT --reject-with icmp-admin-prohibited
        else
            # block aws metadata endpoint (instance IAM Role) for non-system users
            $cmd -A OUTPUT -p tcp -d fd00:ec2::254 -m owner --uid-owner 0 -j ACCEPT
            $cmd -A OUTPUT -p tcp -d fd00:ec2::254 -j REJECT --reject-with icmp6-adm-prohibited
        fi
    elif [[ $allow_idms =~ ^n|no|f|false|0$ ]]; then
        if [[ $cmd = illinois_ip4_rule ]]; then
            # block aws metadata endpoint (instance IAM Role) for all users
            $cmd -A OUTPUT -p tcp -d 169.254.169.254 -j REJECT --reject-with icmp-admin-prohibited
        else
            # block aws metadata endpoint (instance IAM Role) for all users
            $cmd -A OUTPUT -p tcp -d fd00:ec2::254 -j REJECT --reject-with icmp6-adm-prohibited
        fi
    fi

    for proto in icmp udp tcp; do
        $cmd -A OUTPUT -p $proto -m state --state NEW,ESTABLISHED -j ACCEPT
    done
done

illinois_log "saving iptable rules"
/usr/libexec/iptables/iptables.init save
/usr/libexec/iptables/ip6tables.init save

illinois_write_file /etc/sysctl.d/99-illinois-network.conf <<HERE
# IPv4 lockdown
net.ipv4.ip_forward = ${ip_forward}
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.default.log_martians = 1
net.ipv4.conf.default.rp_filter = 1

# IPv6 lockdown
net.ipv6.conf.all.forwarding = ${ip_forward}
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv6.conf.default.accept_redirects = 0
HERE

illinois_log "setting kernel parameters"
sysctl -w net.ipv4.ip_forward=${ip_forward}
sysctl -w net.ipv4.icmp_echo_ignore_broadcasts=1
sysctl -w net.ipv4.icmp_ignore_bogus_error_responses=1
sysctl -w net.ipv4.tcp_syncookies=1
sysctl -w net.ipv4.conf.all.send_redirects=0
sysctl -w net.ipv4.conf.all.accept_source_route=0
sysctl -w net.ipv4.conf.all.accept_redirects=0
sysctl -w net.ipv4.conf.all.secure_redirects=0
sysctl -w net.ipv4.conf.all.log_martians=1
sysctl -w net.ipv4.conf.all.rp_filter=1
sysctl -w net.ipv4.conf.default.send_redirects=0
sysctl -w net.ipv4.conf.default.accept_source_route=0
sysctl -w net.ipv4.conf.default.accept_redirects=0
sysctl -w net.ipv4.conf.default.secure_redirects=0
sysctl -w net.ipv4.conf.default.log_martians=1
sysctl -w net.ipv4.conf.default.rp_filter=1

sysctl -w net.ipv6.conf.all.forwarding=${ip_forward}
sysctl -w net.ipv6.conf.all.accept_source_route=0
sysctl -w net.ipv6.conf.all.accept_redirects=0
sysctl -w net.ipv6.conf.default.accept_source_route=0
sysctl -w net.ipv6.conf.default.accept_redirects=0

sysctl -w net.ipv4.route.flush=1
sysctl -w net.ipv6.route.flush=1

illinois_init_status finished
date > /var/lib/illinois-network-init
