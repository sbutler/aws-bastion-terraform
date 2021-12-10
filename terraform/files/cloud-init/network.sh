#!/bin/bash

# Setup basic secure networking, such as iptable rules and sysctl parameters.

set -e
ILLINOIS_MODULE=network

[[ -e /var/lib/illinois-network-init ]] && exit 0
. /etc/opt/illinois/cloud-init/init.sh

[[ -e /etc/opt/illinois/cloud-init/network.conf ]] && . /etc/opt/illinois/cloud-init/network.conf

: ${ip_forward:=0}
: ${tcp_allow_ports:=""}
: ${udp_allow_ports:=""}

illinois_init_status running

for service in iptables ip6tables ipset; do
    if ! systemctl is-active $service &> /dev/null; then
        illinois_log "starting $service"
        systemctl enable $service
        systemctl start $service
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
INPUT_UDP_ALLOW="123 323 $udp_allow_ports"

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
    else
        $cmd -A INPUT -s ::1 -j DROP
    fi
    $cmd -A INPUT -p icmp -j ACCEPT
    $cmd -A INPUT -p tcp -m state --state ESTABLISHED,RELATED -j ACCEPT
    $cmd -A INPUT -p udp -m state --state ESTABLISHED,RELATED -j ACCEPT
    $cmd -A INPUT -m state --state NEW -j INPUT_illinois_allow

    $cmd -A OUTPUT -o lo -j ACCEPT
    if [[ $cmd = illinois_ip4_rule ]]; then
        # block aws metadata endpoint (instance IAM Role) for non-system users
        $cmd -A OUTPUT -p tcp -d 169.254.169.254 -m owner --uid-owner 0-999 -j ACCEPT
        $cmd -A OUTPUT -p tcp -d 169.254.169.254 -j REJECT --reject-with icmp-admin-prohibited
    fi
    for proto in icmp udp tcp; do
        $cmd -A OUTPUT -p $proto -m state --state NEW,ESTABLISHED -j ACCEPT
    done
done

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
