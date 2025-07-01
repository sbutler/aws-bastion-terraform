#!/bin/bash

# Setup additional domains to add to the DNS Search list. This always includes
# the ad.uillinois.edu domain (last) and the hosts own domain (first).
#
# /etc/opt/illinois/cloud-init/resolv.conf:
#
#   search_domains: space delimited list of domains to add to the search list.

set -e
ILLINOIS_MODULE=resolv

[[ $ILLINOIS_FORCE =~ ^(n|no|f|false|0)?$ && -e /var/lib/illinois-resolv-init ]] && exit 0
. /etc/opt/illinois/cloud-init/init.sh

[[ -e /etc/opt/illinois/cloud-init/resolv.conf ]] && . /etc/opt/illinois/cloud-init/resolv.conf

: ${search_domains:=""}

illinois_init_status running

interface=$(ip -json link show device-number-0 | jq -r 'first | .ifname')
if [[ -z $interface ]]; then
    interface=$(ip -json link show device-number-0.0 | jq -r 'first | .ifname')
fi
if [[ -z $interface ]]; then
    illinois_log error "altname device-number-0 and device-number-0.0 lookup failed"
    exit 1
fi
illinois_log "using interface: $interface"

illinois_search=($search_domains "ad.uillinois.edu")
mydomain=$(dnsdomainname)
if [[ -n $mydomain && ! ($mydomain = "localdomain" || $mydomain = "localdomain6" || $mydomain = "(none)" || $mydomain = *\ *) ]]; then
    illinois_search=("$mydomain" "${illinois_search[@]}")
fi

unitdir="/etc/systemd/network/70-${interface}.network.d"
[[ -e $unitdir ]] || mkdir -p "$unitdir"

unitfile_tmp=$(mktemp -t resolv.XXXXXXXX.conf); tmpfiles+=("$unitfile_tmp")

illinois_write_file "$unitfile_tmp" <<HERE
[Network]
Domains=${illinois_search[@]}

[DHCPv4]
UseHostname=false

[DHCPv6]
UseHostname=false
HERE

unitfile="${unitdir}/illinois-resolv.conf"
network_changed=n
if [[ ! -e $unitfile ]]; then
    cp "$unitfile_tmp" "$unitfile"
    network_changed=y
elif diff -q "$unitfile" "$unitfile_tmp"; then
    illinois_log "No changes in illinois-resolv.conf"
else
    _diff_ec=$?
    if [[ $_diff_ec -eq 1 ]]; then
        cp "$unitfile_tmp" "$unitfile"
        network_changed=y
    else
        illinois_log error "Error comparing files"
        exit $_diff_ec
    fi
fi

if [[ $network_changed = y ]]; then
    illinois_log "Reloading networkd"
    networkctl reload
fi

illinois_init_status finished
date > /var/lib/illinois-resolv-init
