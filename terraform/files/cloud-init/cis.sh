#!/bin/bash

# This performs extra hardening recommended by the CIS Benchmarks. Some of the
# recommendations are present in other scripts, but this one is for the
# miscellaneous items.
#
# /etc/opt/illinois/cloud-init/cis.conf:
#
#   cis_shell_timeout: number of seconds a SH shell will be idle before timing out.

set -e
ILLINOIS_MODULE=cis

[[ $ILLINOIS_FORCE =~ ^(n|no|f|false|0)?$ && -e /var/lib/illinois-cis-init ]] && exit 0
. /etc/opt/illinois/cloud-init/init.sh

[[ -e /etc/opt/illinois/cloud-init/cis.conf ]] && . /etc/opt/illinois/cloud-init/cis.conf

: ${cis_shell_timeout:=900}

illinois_init_status running

illinois_rpm_install authselect

if ! egrep -q '^tmpfs\s+/dev/shm\s+' /etc/fstab; then
    illinois_log "setting /dev/shm mount options"
    echo -e "tmpfs\t/dev/shm\ttmpfs\trw,noexec,nosuid,nodev\t0 0" >> /etc/fstab
    mount -o remount,rw,noexec,nodev,nosuid /dev/shm
fi

illinois_log "securing core files"
sed -i.illinois-cis -r \
    -e 's/^#?\s*Storage=.*/Storage=none/' \
    -e 's/^#?\s*ProcessSizeMax=.*/ProcessSizeMax=0/' \
    /etc/systemd/coredump.conf

illinois_log "setting sysctl parameters"
illinois_write_file /etc/sysctl.d/99-illinois-cis.conf <<HERE
# Kernel
kernel.randomize_va_space = 2
kernel.yama.ptrace_scope = 1
HERE
sysctl -w kernel.randomize_va_space=2
sysctl -w kernel.yama.ptrace_scope=1

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

if [[ $cis_shell_timeout -gt 0 ]]; then
    illinois_log "setting shell timeouts"
    illinois_write_file /etc/profile.d/illinois-cis.sh <<HERE
readonly TMOUT=${cis_shell_timeout} ; export TMOUT
HERE
fi

for unit in nfs-server rpcbind rpcbind.socket; do
    illinois_log "masking systemd unit $unit"
    systemctl --now mask $unit
done

illinois_log "setting up journald"
sed -i.illinois-cis -r \
    -e 's/^#?\s*Storage=.*/Storage=persistent/' \
    -e 's/^#?\s*Compress=.*/Compress=yes/' \
    /etc/systemd/journald.conf
systemctl restart systemd-journald

# Create a custom minimal authselect profile, in case we don't have sssd enabled
[[ -e /etc/authselect/custom/illinois/minimal ]] || mkdir -p /etc/authselect/custom/illinois/minimal

illinois_write_file /etc/authselect/custom/illinois/minimal/README <<"HERE"
Local users only for minimal installations
==========================================

Selecting this profile will enable local files as the source of identity
and authentication providers.

This profile can be used on systems that require minimal installation to
save disk and memory space. It serves only local users and groups directly
from system files instead of going through other authentication providers.
Therefore SSSD, winbind and fprintd packages can be safely removed.

Unless this system has strict memory and disk constraints, it is recommended
to keep SSSD running and use 'sssd' profile to avoid functional limitations.

AVAILABLE OPTIONAL FEATURES
---------------------------

with-faillock::
    Enable account locking in case of too many consecutive
    authentication failures.

with-mkhomedir::
    Enable automatic creation of home directories for users on their
    first login.

with-ecryptfs::
    Enable automatic per-user ecryptfs.

with-silent-lastlog::
    Do not produce pam_lastlog message during login.

with-pamaccess::
    Check access.conf during account authorization.

with-altfiles::
    Use nss_altfiles for passwd and group nsswitch databases.

without-nullok::
    Do not add nullok parameter to pam_unix.

with-duo::
    Enable authentication with Duo Security through pam_duo.

DISABLE SPECIFIC NSSWITCH DATABASES
-----------------------------------

Normally, nsswitch databases set by the profile overwrites values set in
user-nsswitch.conf. The following options can force authselect to
ignore value set by the profile and use the one set in user-nsswitch.conf
instead.

with-custom-aliases::
Ignore "aliases" map set by the profile.

with-custom-automount::
Ignore "automount" map set by the profile.

with-custom-ethers::
Ignore "ethers" map set by the profile.

with-custom-group::
Ignore "group" map set by the profile.

with-custom-hosts::
Ignore "hosts" map set by the profile.

with-custom-initgroups::
Ignore "initgroups" map set by the profile.

with-custom-netgroup::
Ignore "netgroup" map set by the profile.

with-custom-networks::
Ignore "networks" map set by the profile.

with-custom-passwd::
Ignore "passwd" map set by the profile.

with-custom-protocols::
Ignore "protocols" map set by the profile.

with-custom-publickey::
Ignore "publickey" map set by the profile.

with-custom-rpc::
Ignore "rpc" map set by the profile.

with-custom-services::
Ignore "services" map set by the profile.

with-custom-shadow::
Ignore "shadow" map set by the profile.

EXAMPLES
--------

* Enable minimal profile

  authselect select minimal

SEE ALSO
--------
* man passwd(5)
* man group(5)
HERE

illinois_write_file /etc/authselect/custom/illinois/minimal/REQUIREMENTS <<"HERE"
- with-mkhomedir is selected, make sure pam_oddjob_mkhomedir module                       {include if "with-mkhomedir"}
  is present and oddjobd service is enabled and active                                    {include if "with-mkhomedir"}
  - systemctl enable --now oddjobd.service                                                {include if "with-mkhomedir"}
                                                                                          {include if "with-mkhomedir"}
- with-altfiles is selected, make sure nss_altfiles module is present                     {include if "with-altfiles"}
                                                                                          {include if "with-duo"}
- with-duo is selected, make sure pam_duo module is present and configured                {include if "with-duo"}
HERE

illinois_write_file /etc/authselect/custom/illinois/minimal/dconf-db <<"HERE"
[org/gnome/login-screen]
enable-smartcard-authentication=false
enable-fingerprint-authentication=false
HERE

illinois_write_file /etc/authselect/custom/illinois/minimal/dconf-locks <<"HERE"
/org/gnome/login-screen/enable-smartcard-authentication
/org/gnome/login-screen/enable-fingerprint-authentication
HERE

illinois_write_file /etc/authselect/custom/illinois/minimal/fingerprint-auth <<"HERE"
HERE

illinois_write_file /etc/authselect/custom/illinois/minimal/nsswitch.conf <<"HERE"
aliases:    files                                       {exclude if "with-custom-aliases"}
automount:  files                                       {exclude if "with-custom-automount"}
ethers:     files                                       {exclude if "with-custom-ethers"}
group:      files {if "with-altfiles":altfiles }systemd {exclude if "with-custom-group"}
hosts:      resolve [!UNAVAIL=return] files myhostname dns {exclude if "with-custom-hosts"}
initgroups: files                                       {exclude if "with-custom-initgroups"}
netgroup:   files                                       {exclude if "with-custom-netgroup"}
networks:   files                                       {exclude if "with-custom-networks"}
passwd:     files {if "with-altfiles":altfiles }systemd {exclude if "with-custom-passwd"}
protocols:  files                                       {exclude if "with-custom-protocols"}
publickey:  files                                       {exclude if "with-custom-publickey"}
rpc:        files                                       {exclude if "with-custom-rpc"}
services:   files                                       {exclude if "with-custom-services"}
shadow:     files                                       {exclude if "with-custom-shadow"}
HERE

illinois_write_file /etc/authselect/custom/illinois/minimal/password-auth <<"HERE"
auth        required                                     pam_env.so
auth        required                                     pam_faildelay.so delay=2000000
auth        required                                     pam_faillock.so preauth silent                         {include if "with-faillock"}
auth        sufficient                                   pam_unix.so {if not "without-nullok":nullok} try_first_pass {exclude if "with-duo"}
auth        requisite                                    pam_unix.so {if not "without-nullok":nullok} try_first_pass {include if "with-duo"}
auth        sufficient                                   pam_duo.so conf=/etc/duo/pam_duo.conf                  {include if "with-duo"}
auth        required                                     pam_faillock.so authfail                               {include if "with-faillock"}
auth        required                                     pam_deny.so

account     required                                     pam_access.so                                          {include if "with-pamaccess"}
account     required                                     pam_faillock.so                                        {include if "with-faillock"}
account     required                                     pam_unix.so

password    requisite                                    pam_pwquality.so try_first_pass enforce_for_root retry=3
password    sufficient                                   pam_unix.so sha512 shadow {if not "without-nullok":nullok} try_first_pass use_authtok
password    required                                     pam_deny.so

session     optional                                     pam_keyinit.so revoke
session     required                                     pam_limits.so
session     optional                                     pam_ecryptfs.so unwrap                                {include if "with-ecryptfs"}
-session    optional                                     pam_systemd.so
session     optional                                     pam_oddjob_mkhomedir.so                               {include if "with-mkhomedir"}
session     [success=1 default=ignore]                   pam_succeed_if.so service in crond quiet use_uid
session     required                                     pam_unix.so
HERE

illinois_write_file /etc/authselect/custom/illinois/minimal/postlogin <<"HERE"
auth        optional                   pam_ecryptfs.so unwrap                                 {include if "with-ecryptfs"}

password    optional                   pam_ecryptfs.so unwrap                                 {include if "with-ecryptfs"}

session     optional                   pam_umask.so silent
session     [success=1 default=ignore] pam_succeed_if.so service !~ gdm* service !~ su* quiet
session     [default=1]                pam_lastlog.so nowtmp {if "with-silent-lastlog":silent|showfailed}
session     optional                   pam_lastlog.so silent noupdate showfailed
HERE

illinois_write_file /etc/authselect/custom/illinois/minimal/smartcard-auth <<"HERE"
HERE

illinois_write_file /etc/authselect/custom/illinois/minimal/system-auth <<"HERE"
auth        required                                     pam_env.so
auth        required                                     pam_faildelay.so delay=2000000
auth        required                                     pam_faillock.so preauth silent                         {include if "with-faillock"}
auth        sufficient                                   pam_unix.so {if not "without-nullok":nullok} try_first_pass {exclude if "with-duo"}
auth        requisite                                    pam_unix.so {if not "without-nullok":nullok} try_first_pass {include if "with-duo"}
auth        sufficient                                   pam_duo.so conf=/etc/duo/pam_duo.conf                  {include if "with-duo"}
auth        required                                     pam_faillock.so authfail                               {include if "with-faillock"}
auth        required                                     pam_deny.so

account     required                                     pam_access.so                                          {include if "with-pamaccess"}
account     required                                     pam_faillock.so                                        {include if "with-faillock"}
account     required                                     pam_unix.so

password    requisite                                    pam_pwquality.so try_first_pass enforce_for_root retry=3
password    requisite                                    pam_pwhistory.so remember=5 use_authtok
password    sufficient                                   pam_unix.so sha512 shadow {if not "without-nullok":nullok} try_first_pass use_authtok
password    required                                     pam_deny.so

session     optional                                     pam_keyinit.so revoke
session     required                                     pam_limits.so
session     optional                                     pam_ecryptfs.so unwrap                                {include if "with-ecryptfs"}
-session    optional                                     pam_systemd.so
session     optional                                     pam_oddjob_mkhomedir.so                               {include if "with-mkhomedir"}
session     [success=1 default=ignore]                   pam_succeed_if.so service in crond quiet use_uid
session     required                                     pam_unix.so
HERE

if ! authselect current >/dev/null; then
    illinois_log "setting illinois/minimal authselect profile"
    authselect select custom/illinois/minimal with-faillock --force
fi

if ! egrep -q '^auth\s+required\s+pam_wheel.so' /etc/pam.d/su; then
    illinois_log "securing su"
    sed -i.illinois-sss -re 's/^#(auth\s+required\s+pam_wheel.so\s+use_uid)$/auth            required        pam_wheel.so use_uid group=wheel/' /etc/pam.d/su
fi

illinois_log "setting pwquality"
sed -i.illinois-cis -r \
    -e 's/^#?\s*minlen\s+=.*/minlen = 14/' \
    -e 's/^#?\s*(dcredit|ucredit|ocredit|lcredit)\s+=.*/\1 = -1/' \
    /etc/security/pwquality.conf

illinois_log "setting faillock"
sed -i.illinois-cis -r \
    -e 's/^#?\s*deny\s+=.*/deny = 5/' \
    -e 's/^#?\s*unlock_time\s+=.*/unlock_time = 900/' \
    /etc/security/faillock.conf
if ! authselect current | egrep -q '^Enabled features:.*with-faillock'; then
    illinois_log "enabling faillock"
    authselect enable-feature with-faillock
fi

for file in profile bashrc; do
    illinois_log "$file: setting restrictive umask"
    sed -i.illinois-cis -re 's/^(\s*umask\s+).*/\1027/' /etc/$file
done
sed -i.illinois-cis-umask -r \
    -e 's/^(s*UMASK\s+).*/\1027/' \
    -e 's/^(s*USERGROUPS_ENAB\s+).*/\1no/' \
    /etc/login.defs

illinois_log "setting max/min password age"
sed -i.illinois-cis-passage -r \
    -e 's/^(s*PASS_MAX_DAYS\s+).*/\1365/' \
    -e 's/^(s*PASS_MIN_DAYS\s+).*/\11/' \
    /etc/login.defs

illinois_log "setting inactive password lock"
useradd -D -f 30

illinois_init_status finished
date > /var/lib/illinois-cis-init
