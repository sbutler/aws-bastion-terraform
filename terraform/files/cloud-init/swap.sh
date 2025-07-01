#cloud-boothook
#!/bin/bash

# Creates and activates a swapfile for extra memory.
#
# /etc/opt/illinois/cloud-init/swap.conf
#
#   swap_file: file to use for swap. Default: /var/vm/swapfile
#   swap_size: size for the swapfile. Default: 4G

set -e
ILLINOIS_MODULE=swap

[[ $ILLINOIS_FORCE =~ ^(n|no|f|false|0)?$ && -e /var/lib/illinois-swap-init ]] && exit 0
. /etc/opt/illinois/cloud-init/init.sh

[[ -e /etc/opt/illinois/cloud-init/swap.conf ]] && . /etc/opt/illinois/cloud-init/swap.conf

: ${swap_file:=/var/vm/swapfile}
: ${swap_size:=4G}

illinois_init_status running

if [[ ! -e $swap_file ]]; then
    swap_dir=$(dirname "$swap_file")
    if [[ ! -e $swap_dir ]]; then
        illinois_log "Creating $swap_dir"
        mkdir -p "$swap_dir"
    fi

    illinois_log "Creating $swap_file (size: $swap_size)"
    fallocate -l $swap_size "$swap_file"
    chown root:root "$swap_file"
    chmod u=rw,g=,o= "$swap_file"

    mkswap "$swap_file"
fi
[[ -e /usr/local/lib/systemd/system ]] || mkdir -p /usr/local/lib/systemd/system

swap_unit=$(systemd-escape --path --suffix swap "$swap_file")
if [[ ! -e "/usr/local/lib/systemd/system/$swap_unit" ]]; then
    illinois_log "Creating $swap_unit"
    illinois_write_file "/usr/local/lib/systemd/system/$swap_unit" <<HERE
[Unit]
Description=Instance Swap

[Swap]
What=${swap_file}

[Install]
WantedBy=swap.target
HERE

    systemctl daemon-reload
fi

if ! systemctl is-enabled $swap_unit; then
    illinois_log "Enabling $swap_unit"
    systemctl enable $swap_unit

    if systemctl is-active swap.target; then
        illinois_log "Starting $swap_unit"
        systemctl start $swap_unit
    fi
fi

illinois_init_status finished
date > /var/lib/illinois-swap-init
