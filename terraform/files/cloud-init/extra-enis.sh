#!/bin/bash

# Installs various networking units so that added interfaces get the proper
# configuration. The routing tables are setup using AWS prefix list entries.
# When specifying the interface in the config, you can use the persistent name,
# the device number (device-number-X), or the ENI ID (eni-XXXXXXXX).
#
# Note: this does not actually create and attach the ENIs, it is
# expected a Lambda will do that.
#
# /etc/opt/illinois/cloud-init/extra-enis.conf:
#
#   extra_enis_table_id: associative array where each key is the name of an
#       interface (device-index-0, etc) and the value is the table id to use for
#       route rules.
#   extra_enis_prefix_list_ids: associative array where each key is the name of
#       an interface (device-index-0, etc) and the value is a space deliminated
#       list of prefix-id's to add routes for over that interface.

set -e
ILLINOIS_MODULE=extra-enis

[[ $ILLINOIS_FORCE =~ ^(n|no|f|false|0)?$ && -e /var/lib/illinois-extra-enis-init ]] && exit 0
. /etc/opt/illinois/cloud-init/init.sh

[[ -e /etc/opt/illinois/cloud-init/extra-enis.conf ]] && . /etc/opt/illinois/cloud-init/extra-enis.conf

: ${extra_enis_update_interval:=0}
declare -A extra_enis_prefix_list_ids
declare -A extra_enis_table_id

illinois_init_status running


illinois_write_file /usr/local/bin/illinois-extra-enis root:root 0700 <<"EOF_SCRIPT"
#!/bin/bash

set -e
ILLINOIS_MODULE=extra-enis

. /etc/opt/illinois/cloud-init/init.sh

[[ -e /etc/opt/illinois/cloud-init/extra-enis.conf ]] && . /etc/opt/illinois/cloud-init/extra-enis.conf

declare -A extra_enis_prefix_list_ids
declare -A extra_enis_table_id

network_changed=n
process_eni () {
    local interface=$1
    local table_id=$2
    local prefix_lists=($3)

    if [[ -z $interface ]]; then
        illinois_log err "No interface"
        return 1
    elif [[ ${#prefix_lists[@]} -eq 0 ]]; then
        illinois_log error "[$interface] No prefix lists"
        return 1
    fi

    local _interface_info _interface_info_tries=0
    while :; do
        _interface_info="$(ip -json link show ${interface} | jq 'first')"
        [[ -n $_interface_info ]] && break

        (( _interface_info_tries++ ))
        if (( _interface_info_tries >= 15 )); then
            illinois_log err "[$interface] interface not found after 15 tries"
            return 1
        fi
        sleep 2
    done

    local _interface=$(echo "$_interface_info" | jq -r '.ifname')
    if [[ -z $_interface ]]; then
        illinois_log err "[$interface] altname lookup failed"
        return 1
    fi
    illinois_log "[$interface] using interface: $_interface"

    if [[ -z $table_id ]]; then
        local _interface_mac="$(echo "$_interface_info" | jq -r '.address')"
        local _interface_devicenum=$(illinois_aws_metadata network/interfaces/macs/$_interface_mac/device-number)
        local _interface_networkcard=$(illinois_aws_metadata network/interfaces/macs/$_interface_mac/network-card-id)

        if [[ -n $_interface_devicenum ]]; then
            table_id=$(( 10000 + 100 * _interface_networkcard + _interface_devicenum ))
        else
            illinois_log err "[$interface] no table_id or ability to calculate one from device-number and network-card-id"
            return 1
        fi
    fi

    local unitdir="/etc/systemd/network/70-${_interface}.network.d"
    [[ -e $unitdir ]] || mkdir -p "$unitdir"

    local unitfile_tmp=$(mktemp -t extra-enis.XXXXXXXX.conf); tmpfiles+=("$unitfile_tmp")
    cat <<EOF_UNIT > "$unitfile_tmp"
# Generated file from ${prefix_lists[@]}
[DHCPv4]
UseGateway=false
UseDNS=false
UseNTP=false
UseHostname=false
UseDomains=false

[DHCPv6]
UseDNS=false
UseNTP=false
UseHostname=false
UseDomains=false

EOF_UNIT

    for pl in ${prefix_lists[@]}; do
        illinois_log "[$interface] adding prefix-list routes: $pl"
        for prefix_cidr in $(aws ec2 get-managed-prefix-list-entries \
            --prefix-list-id $pl \
            --output text \
            --query 'join(`" "`, Entries[].Cidr)'); do
          illinois_log "[$interface] adding route: $prefix_cidr"
          echo -e "[Route]\nGateway=_dhcp4\nDestination=${prefix_cidr}\n" >> "$unitfile_tmp"
        done
    done

    local unitfile="${unitdir}/illinois-extra-eni.conf"
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
}

has_errors=n
for extra_eni in "${!extra_enis_prefix_list_ids[@]}"; do
    if ! process_eni $extra_eni "${extra_enis_table_id[$extra_eni]}" "${extra_enis_prefix_list_ids[$extra_eni]}"; then
        has_errors=y
    fi
done

if [[ $network_changed = y ]]; then
    illinois_log "Reloading networkd"
    networkctl reload
fi

[[ $has_errors = n ]] || exit 1
EOF_SCRIPT


[[ -e /usr/local/lib/systemd/system ]] || mkdir -p /usr/local/lib/systemd/system
illinois_write_file /usr/local/lib/systemd/system/illinois-extra-enis-update.service <<EOF
[Unit]
Description="Extra ENI Route Updates"
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/illinois-extra-enis
EOF

illinois_write_file /usr/local/lib/systemd/system/illinois-extra-enis-update.timer <<EOF
[Unit]
Description="Extra ENI Route Updates"

[Timer]
OnUnitActiveSec=${extra_enis_update_interval}d
OnBootSec=1s

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload

illinois_init_status finished
date > /var/lib/illinois-extra-enis-init

if [[ $extra_enis_update_interval -gt 0 ]]; then
    systemctl enable --now illinois-extra-enis-update.timer
else
    /usr/local/bin/illinois-extra-enis
fi

