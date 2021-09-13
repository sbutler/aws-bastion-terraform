#!/bin/bash

# Perform extra hardening for CIS Benchmarks, not present in other scripts. Options
# available in /etc/opt/illinois/cloud-init/cis.conf:
#
#   cis_shell_timeout: number of seconds a SH shell will be idle before timing out.

set -e
ILLINOIS_MODULE=cis

[[ -e /var/lib/illinois-cis-init ]] && exit 0
. /etc/opt/illinois/cloud-init/init.sh

[[ -e /etc/opt/illinois/cloud-init/cis.conf ]] && . /etc/opt/illinois/cloud-init/cis.conf

: ${cis_shell_timeout:=3600}

illinois_init_status running

illinois_log "disabling kernel modules"
illinois_write_file /etc/modprobe.d/illinois-cis.conf <<HERE
install cramfs /bin/true
install udf /bin/true
install usb-storage /bin/true
HERE

if ! egrep -q '^tmpfs\s+/dev/shm\s+' /etc/fstab; then
    illinois_log "setting /dev/shm mount options"
    echo -e "tmpfs\t/dev/shm\ttmpfs\trw,noexec,nosuid,nodev\t0 0" >> /etc/fstab
    mount -o remount,rw,noexec,nodev,nosuid /dev/shm
fi

for file in grub.cfg user.cfg; do
    if [[ -f /boot/grub2/$file ]]; then
        illinois_log "securing /boot/grub2/$file"
        chown root:root /boot/grub2/$file
        chmod og-rwx /boot/grub2/$file
    fi
done

illinois_log "securing core files"
illinois_write_file /etc/security/limits.d/illinois-cis.conf <<HERE
* hard core 0
HERE

illinois_log "setting sysctl parameters"
illinois_write_file /etc/sysctl.d/99-illinois-cis.conf <<HERE
# Kernel
fs.suid_dumpable = 0
kernel.randomize_va_space = 2
HERE
sysctl -w fs.suid_dumpable=0
sysctl -w kernel.randomize_va_space=2

illinois_log "securing sudo"
illinois_write_file /etc/sudoers.d/illinois-cis root:root 0640 <<HERE
Defaults use_pty
Defaults logfile="/var/log/sudo.log"
HERE
illinois_write_file /etc/logrotate.d/sudolog <<HERE
/var/log/sudo.log
{
    missingok
    weekly
    copytruncate
    rotate 12
}
HERE

if ! egrep -q '^auth\s+required\s+pam_wheel.so' /etc/pam.d/su; then
    illinois_log "securing su"
    sed -i.illinois-cis -re 's/^#(auth\s+required\s+pam_wheel.so\s+use_uid)$/\1/' /etc/pam.d/su
fi

illinois_log "setting login banners"
illinois_write_file /etc/issue <<HERE
====================================================================
| This system is for the use of authorized users only.  Usage of   |
| this system may be monitored and recorded by system personnel.   |
|                                                                  |
| Anyone using this system expressly consents to such monitoring   |
| and is advised that if such monitoring reveals possible          |
| evidence of criminal activity, system personnel may provide the  |
| evidence from such monitoring to law enforcement officials.      |
====================================================================
HERE
illinois_write_file /etc/issue.net <<HERE
====================================================================
| This system is for the use of authorized users only.  Usage of   |
| this system may be monitored and recorded by system personnel.   |
|                                                                  |
| Anyone using this system expressly consents to such monitoring   |
| and is advised that if such monitoring reveals possible          |
| evidence of criminal activity, system personnel may provide the  |
| evidence from such monitoring to law enforcement officials.      |
====================================================================
HERE

illinois_log "setting shell timeouts"
illinois_write_file /etc/profile.d/illinois-cis.conf <<HERE
readonly TMOUT=${cis_shell_timeout} ; export TMOUT
HERE

# This is pointless since chrony already runs as this user, but make CIS happy
sed -i -re 's/^\s*OPTIONS="(.*)"$/OPTIONS="-u chrony \1"/' /etc/sysconfig/chronyd

for unit in nfs-server rpcbind rpcbind.socket rsyncd; do
    illinois_log "masking systemd unit $unit"
    systemctl --now mask $unit
done

illinois_log "setting up journald"
sed -i -re 's/^#?\s*Storage=.*/Storage=persistent/; s/^#?\s*Compress=.*/Compress=yes/;' /etc/systemd/journald.conf
systemctl restart systemd-journald

illinois_init_status finished
date > /var/lib/illinois-cis-init
