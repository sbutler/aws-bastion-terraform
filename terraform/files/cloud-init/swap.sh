#cloud-boothook

# Creates and activates a swapfile for extra memory. Options available:
#
#   swap_file: file to use for swap. Default: /var/vm/swapfile
#   swap_unit: name of the swap unit file: Default: var-vm-swapfile.swap
#   swap_size: size for the swapfile. Default: 4G

set -e
ILLINOIS_MODULE=swap

[[ -e /var/lib/illinois-swap-init ]] && exit 0
. /etc/opt/illinois/cloud-init/init.sh

[[ -e /etc/opt/illinois/cloud-init/swap.conf ]] && . /etc/opt/illinois/cloud-init/swap.conf

: ${swap_file:=/var/vm/swapfile}
: ${swap_unit:=var-vm-swapfile.swap}
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

if [[ ! -e "/etc/systemd/system/${swap_unit}" ]]; then
    illinois_log "Creating $swap_unit"
    illinois_write_file "/etc/systemd/system/${swap_unit}" <<HERE
[Unit]
Description=Instance Swap

[Swap]
What=${swap_file}

[Install]
WantedBy=multi-user.target
HERE
fi

if ! systemctl is-enabled "$swap_unit"; then
    illinois_log "Enabling $swap_unit"
    systemctl enable --now "$swap_unit"
fi

illinois_init_status finished
date > /var/lib/illinois-swap-init
