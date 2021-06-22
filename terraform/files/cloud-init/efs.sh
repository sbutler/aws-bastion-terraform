#cloud-boothook

# Mounts EFS volumes configured in "/etc/opt/illinois/cloud-init/efs" inside "/mnt"
# based on the name of the file in the configuration directory. Options
# available for each mount:
#
#   efs_filesystem_id: the fs-XXXXXXXX ID to mount. Required.
#   mount_target: where to mount at. Default: /mnt/<config name>
#   nfs_options: options to pass to mount_nfs4. Default: nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2

set -e
ILLINOIS_MODULE=efs

[[ -e /var/lib/illinois-efs-init ]] && exit 0
. /etc/opt/illinois/cloud-init/init.sh

illinois_rpm_install nfs-utils amazon-efs-utils

illinois_init_status running

illinois_efs_mount () {
    local name=$(basename "$1")
    local efs_filesystem_id=''
    local mount_target="/mnt/${name}"
    local efs_options="tls,noresvport"

    . "$1"

    if [[ -z $efs_filesystem_id ]]; then
        illinois_log err "${name} does not have an 'efs_filesystem_id' set"
        return
    fi

    local dir_src="$efs_filesystem_id"
    local dir_tgt="$mount_target"

    if ! egrep -q "^${dir_src}:/\s+${mount_target}\s+" /etc/fstab; then
        [[ -e $dir_tgt ]] || mkdir -p "${dir_tgt}"
        if ! mount -t efs -o "${efs_options}" "${dir_src}:/" "${dir_tgt}"; then
            illinois_log err "${name} mounting ${dir_src} to ${dir_tgt} failed"
            return
        fi

        local fstab_options='_netdev'
        if [[ -n $efs_options ]]; then
            fstab_options="$efs_options,_netdev"
        fi
        echo -e "${dir_src}:/\t${dir_tgt}\tefs\t${fstab_options}\t0\t0" | tee -a /etc/fstab
    fi
}

cp -p /etc/fstab /etc/fstab.bak-efs
for efs_config in /etc/opt/illinois/cloud-init/efs/*; do
    [[ -f "$efs_config" ]] || continue
    illinois_efs_mount "$efs_config"
done

illinois_init_status finished
date > /var/lib/illinois-efs-init
