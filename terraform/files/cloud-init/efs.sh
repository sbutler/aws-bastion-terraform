#cloud-boothook
#!/bin/bash

# Configures EFS volumes to mount on the instance. The simpliest configuration
# is to host the instance and the EFS Mount Targets in the same VPC. However,
# you can also mount EFS volumes across VPCs, if you're careful.
#
# The script will exit for a filesystem if the mount point is already mounted
# by another filesystem.
#
# /etc/opt/illinois/cloud-init/efs/$name:
#
#   efs_filesystem_id: the fs-XXXXXXXX ID to mount. Required.
#   efs_mount_targets: bash associative array of AZ names to IP address for
#       the EFS mount target. Only use this if your EFS mount targets are not in
#       the same VPC as the instance, or if you are not using Amazon VPC DNS.
#   efs_options: options to pass to mount.efs. Default: noresvport
#   mount_target: where to mount at. Default: /mnt/<config name>

set -e
ILLINOIS_MODULE=efs

[[ $ILLINOIS_FORCE =~ ^(n|no|f|false|0)?$ && -e /var/lib/illinois-efs-init ]] && exit 0
. /etc/opt/illinois/cloud-init/init.sh

illinois_rpm_install nfs-utils amazon-efs-utils

illinois_init_status running

efs_az="$(illinois_aws_metadata placement/availability-zone)"
efs_region="$(illinois_aws_metadata placement/region)"

illinois_efs_mount () {
    local name=$(basename "$1")
    local efs_filesystem_id mount_target efs_options
    declare -A efs_mount_targets=()

    . "$1"

    if [[ -z $efs_filesystem_id ]]; then
        illinois_log err "[$name] no 'efs_filesystem_id' set"
        return 1
    fi

    : ${mount_target:=/mnt/${name}}
    : ${efs_options:=tls,noresvport}

    local efs_tgt_ip=${efs_mount_targets[$efs_az]}
    if [[ -n $efs_tgt_ip ]]; then
        if ! egrep -q "^${efs_tgt_ip}\s+" /etc/hosts; then
            local efs_tgt_host="$efs_filesystem_id.efs.${efs_region}.amazonaws.com"

            illinois_log "[$name] adding $efs_tgt_ip $efs_tgt_host to /etc/hosts"
            echo "$efs_tgt_ip $efs_tgt_host" >> /etc/hosts
        fi
    fi

    local dir_src="$efs_filesystem_id:/"
    local dir_tgt="$mount_target"
    local unitfile=$(systemd-escape --path --suffix mount "$dir_tgt")

    local dir_tgt_device="$(awk -v mp=$dir_tgt '$2 == mp { print $1 }' /proc/mounts)"
    if [[ -n $dir_tgt_device ]]; then
        # We can't look at the device to see if it's the correct EFS, b/c with
        # TLS all the devices are localhost. So we just check if the mount unit
        # is active.
        if ! systemclt -q is-active $unitfile; then
            illinois_log "[$name] mount point already mounted: $dir_tgt_device"
            return 1
        fi
    fi

    illinois_write_file "/usr/local/lib/systemd/system/$unitfile" <<EOF
[Unit]
Description=Data mount: $name ($efs_filesystem_id)

[Mount]
What=$dir_src
Where=$dir_tgt
Type=efs
Options=$efs_options

[Install]
WantedBy=remote-fs.target
EOF
    systemctl daemon-reload

    illinois_log "[$_lv] reloading systemd and mounting the filesystem"
    systemclt enable $unitfile
    if systemctl is-active remote-fs.target; then
        systemctl start $unitfile
    fi
}

[[ -e /usr/local/lib/systemd/system ]] || mkdir -p /usr/local/lib/systemd/system
for efs_config in /etc/opt/illinois/cloud-init/efs/*; do
    [[ -f "$efs_config" ]] || continue
    illinois_efs_mount "$efs_config" || :
done

illinois_init_status finished
date > /var/lib/illinois-efs-init
