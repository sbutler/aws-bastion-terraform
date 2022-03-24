#cloud-boothook

# Creates and activates a swapfile for extra memory. This only runs if no swap
# is currently active. Options available:
#
#   swap_file: file to use for swap. Default: /swapfile
#   swap_size: size for the swapfile. Default: 4G

set -e
ILLINOIS_MODULE=swap

. /etc/opt/illinois/cloud-init/init.sh

[[ -e /etc/opt/illinois/cloud-init/swap.conf ]] && . /etc/opt/illinois/cloud-init/swap.conf

: ${swap_file:=/swapfile}
: ${swap_size:=4G}

if [[ -z $(swapon -s) ]]; then
    if [[ ! -e $swap_file ]]; then
        illinois_log "Creating $swap_file (size: $swap_size)"
        fallocate -l $swap_size "$swap_file"
        mkswap "$swap_file"
    fi
    chown root:root "$swap_file"
    chmod u=rw,g=,o= "$swap_file"

    illing_log "Activating $swap_file"
    swapon /swapfile

    swapon -s
fi
