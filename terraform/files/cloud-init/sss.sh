#!/bin/bash

# Setup sssd to connect to ad.uillinois.edu and use uiucEduSSHPublicKey for
# the authorized keys. It will also setup sudo access for members of an admin
# group.
#
# /etc/opt/illinois/cloud-init/sss.conf:
#
#   sss_binduser_parameter: SSM Parameter Store path for the username to bind as.
#   sss_bindpass_parameter: SSM Parameter Store path for the password to bind as.
#   sss_admingroups_parameter: SSM Parameter Store path for the admin groups.
#   sss_allowgroups_parameter: SSM Parameter Store path for the allow groups.
#   sss_admin_groups: array of UOFI groups with admin access.
#   sss_allow_groups: array of UOFI groups with shell access.
#   sss_override_homedir: where the UOFI user homedir should be.
#   sss_override_gid: primary GID to override.
#
# If both sss_admingroups_parameters and sss_allowgroups_parameters are set,
# then they will be used for the groups and sss_admin_groups and sss_allow_groups
# will be ignored.

set -e
ILLINOIS_MODULE=sss

[[ $ILLINOIS_FORCE =~ ^(n|no|f|false|0)?$ && -e /var/lib/illinois-sss-init ]] && exit 0
. /etc/opt/illinois/cloud-init/init.sh

[[ -e /etc/opt/illinois/cloud-init/sss.conf ]] && . /etc/opt/illinois/cloud-init/sss.conf

: ${sss_override_homedir:="/home/%d/%u"}

declare -a sss_admin_groups
declare -a sss_allow_groups
[[ ${#sss_allow_groups[@]} -gt 0 ]] || sss_allow_groups=("domain users")

if [[ -z $sss_binduser_parameter ]]; then
    illinois_log err "no sss_binduser_parameter specified"
    exit 1
fi
if [[ -z $sss_bindpass_parameter ]]; then
    illinois_log err "no sss_bindpass_parameter specified"
    exit 1
fi

illinois_init_status running

illinois_rpm_install authselect sssd sssd-ldap oddjob oddjob-mkhomedir python3-dnf-plugin-post-transaction-actions

illinois_log "getting bind username from SSM $sss_binduser_parameter"
bindcreds_user="$(illinois_get_param "$sss_binduser_parameter")"
illinois_log "getting bind password from SSM $sss_bindpass_parameter"
bindcreds_pass="$(illinois_get_param "$sss_bindpass_parameter")"

if [[ -n $sss_admingroups_parameter && -n $sss_allowgroups_parameter ]]; then
    illinois_log "getting the admin groups from SSM $sss_admingroups_parameter"
    readarray -t sss_admin_groups <<<  "$(illinois_get_listparam "$sss_admingroups_parameter")"
    illinois_log "getting the admin groups from SSM $sss_allowgroups_parameter"
    readarray -t sss_allow_groups <<< "$(illinois_get_listparam "$sss_allowgroups_parameter" "")"
fi

# Add the admin groups to the allow groups, make sure the list of groups is
# unique and doesn't have any blanks. Also, quote the admin groups values for
# use in a sudoers file.
_sss_admin_groups=("${sss_admin_groups[@]}")
_sss_allow_groups=("${sss_allow_groups[@]}" "${sss_admin_groups[@]}")

IFS=$'\n'
_sss_admin_groups=($(sort -u <<< "${_sss_admin_groups[*]}"))
_sss_allow_groups=($(sort -u <<< "${_sss_allow_groups[*]}"))
unset IFS

for i in ${!_sss_admin_groups[@]}; do
    _sss_admin_groups[$i]="\"%${_sss_admin_groups[$i]}\""
done
sss_admin_groups=$(IFS=,; echo "${_sss_admin_groups[*]}")
sss_allow_groups=$(IFS=,; echo "${_sss_allow_groups[*]}")

illinois_log "will bind as ${bindcreds_user}"

cat > /etc/sssd/sssd.conf <<EOF
[sssd]
domains = ad.uillinois.edu
services = nss, pam, ssh
config_file_version = 2

[nss]
filter_groups = root, wheel
filter_users = root, ec2-user

[domain/ad.uillinois.edu]
id_provider = ldap
auth_provider = ldap
access_provider = simple

; Providers we aren't going to use
chpass_provider = none
sudo_provider = none
selinux_provider = none
autofs_provider = none
hostid_provider = none

ldap_uri = ldap://ldap-ad-aws.ldap.illinois.edu
ldap_schema = ad
ldap_referrals = false
ldap_id_use_start_tls = true
ldap_tls_reqcert = never

case_sensitive = false
ignore_group_members = true
; ldap_group_nesting_level = 0
ldap_use_tokengroups = true
; ldap_deref_threshold = 0
ldap_user_ssh_public_key = uiucEduSSHPublicKey

ldap_default_bind_dn = ${bindcreds_user}
ldap_default_authtok = ${bindcreds_pass}

; ID mapping parameters
ldap_id_mapping = true
ldap_idmap_range_min = 2000000
ldap_idmap_range_max = 2002000000
ldap_idmap_range_size = 40000000
ldap_idmap_default_domain_sid = S-1-5-21-2509641344-1052565914-3260824488

; Access parameters
simple_allow_groups = ${sss_allow_groups}

; General overrides
override_homedir = ${sss_override_homedir}
EOF
[[ -n $sss_override_gid ]] && echo "override_gid = ${sss_override_gid}" >> /etc/sssd/sssd.conf
chmod 0600 /etc/sssd/sssd.conf

[[ -e /etc/authselect/custom/illinois/sssd ]] || mkdir -p /etc/authselect/custom/illinois/sssd

illinois_write_file /etc/authselect/custom/illinois/sssd/README <<"HERE"
Enable SSSD for system authentication (also for local users only)
=================================================================

Selecting this profile will enable SSSD as the source of identity
and authentication providers.

SSSD provides a set of daemons to manage access to remote directories
and authentication mechanisms such as LDAP, Kerberos or FreeIPA. It provides
an NSS and PAM interface toward the system and a pluggable backend system
to connect to multiple different account sources.

More information about SSSD can be found on its project page:
https://pagure.io/SSSD/sssd

By default, local users are served from SSSD rather then local files if SSSD
is enabled (however they authenticate via pam_unix). This has a performance
benefit since SSSD caches the files content in fast in-memory cache and thus
reduces number of disk operations.

However, if you do not want to keep SSSD running on your machine, you can
keep this profile selected and just disable SSSD service. The resulting
configuration will still work correctly even with SSSD disabled and local users
and groups will be read from local files directly.

SSSD CONFIGURATION
------------------

Authselect does not touch SSSD's configuration. Please, read SSSD's
documentation to see how to configure it manually. Only local users
will be available on the system if there is no existing SSSD configuration.

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

with-smartcard::
    Enable authentication with smartcards through SSSD. Please note that
    smartcard support must be also explicitly enabled within
    SSSD's configuration.

with-smartcard-lock-on-removal::
    Lock screen when a smartcard is removed.

with-smartcard-required::
    Smartcard authentication is required. No other means of authentication
    (including password) will be enabled.

with-fingerprint::
    Enable authentication with fingerprint reader through *pam_fprintd*.

with-pam-u2f::
    Enable authentication via u2f dongle through *pam_u2f*.

with-pam-u2f-2fa::
    Enable 2nd factor authentication via u2f dongle through *pam_u2f*.

without-pam-u2f-nouserok::
    Module argument nouserok is omitted if also with-pam-u2f-2fa is used.
    *WARNING*: Omitting nouserok argument means that users without pam-u2f
    authentication configured will not be able to log in *INCLUDING* root.
    Make sure you are able to log in before losing root privileges.

with-silent-lastlog::
    Do not produce pam_lastlog message during login.

with-sudo::
    Allow sudo to use SSSD as a source for sudo rules in addition of /etc/sudoers.

with-pamaccess::
    Check access.conf during account authorization.

with-files-access-provider::
    If set, account management for local users is handled also by pam_sss. This
    is needed if there is an explicitly configured domain with id_provider=files
    and non-empty access_provider setting in sssd.conf.

    *WARNING:* SSSD access check will become mandatory for local users and
    if SSSD is stopped then local users will not be able to log in. Only
    system accounts (as defined by pam_usertype, including root) will be
    able to log in.

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

with-custom-passwd::
Ignore "passwd" database set by the profile.

with-custom-group::
Ignore "group" database set by the profile.

with-custom-netgroup::
Ignore "netgroup" database set by the profile.

with-custom-automount::
Ignore "automount" database set by the profile.

with-custom-services::
Ignore "services" database set by the profile.

EXAMPLES
--------

* Enable SSSD with sudo and smartcard support

  authselect select sssd with-sudo with-smartcard

* Enable SSSD with sudo support and create home directories for users on their
  first login

  authselect select sssd with-mkhomedir with-sudo

SEE ALSO
--------
* man sssd.conf(8)
HERE

illinois_write_file /etc/authselect/custom/illinois/sssd/REQUIREMENTS <<"HERE"
Make sure that SSSD service is configured and enabled. See SSSD documentation for more information.
                                                                                          {include if "with-smartcard"}
- with-smartcard is selected, make sure smartcard authentication is enabled in sssd.conf: {include if "with-smartcard"}
  - set "pam_cert_auth = True" in [pam] section                                           {include if "with-smartcard"}
                                                                                          {include if "with-fingerprint"}
- with-fingerprint is selected, make sure fprintd service is configured and enabled       {include if "with-fingerprint"}
                                                                                          {include if "with-pam-u2f"}
- with-pam-u2f is selected, make sure that the pam u2f module is installed                {include if "with-pam-u2f"}
  - users can then configure keys using the pamu2fcfg tool                                {include if "with-pam-u2f"}
                                                                                          {include if "with-pam-u2f-2fa"}
- with-pam-u2f-2fa is selected, make sure that the pam u2f module is installed            {include if "with-pam-u2f-2fa"}
  - users can then configure keys using the pamu2fcfg tool                                {include if "with-pam-u2f-2fa"}
                                                                                          {include if "with-mkhomedir"}
- with-mkhomedir is selected, make sure pam_oddjob_mkhomedir module                       {include if "with-mkhomedir"}
  is present and oddjobd service is enabled and active                                    {include if "with-mkhomedir"}
  - systemctl enable --now oddjobd.service                                                {include if "with-mkhomedir"}
                                                                                          {include if "with-duo"}
- with-duo is selected, make sure pam_duo module is present and configured                {include if "with-duo"}
HERE

illinois_write_file /etc/authselect/custom/illinois/sssd/dconf-db <<"HERE"
{imply "with-smartcard" if "with-smartcard-required"}
{imply "with-smartcard" if "with-smartcard-lock-on-removal"}
[org/gnome/login-screen]
enable-smartcard-authentication={if "with-smartcard":true|false}
enable-fingerprint-authentication={if "with-fingerprint":true|false}
enable-password-authentication={if "with-smartcard-required":false|true}

[org/gnome/settings-daemon/peripherals/smartcard] {include if "with-smartcard-lock-on-removal"}
removal-action='lock-screen'                      {include if "with-smartcard-lock-on-removal"}
HERE

illinois_write_file /etc/authselect/custom/illinois/sssd/dconf-locks <<"HERE"
/org/gnome/login-screen/enable-smartcard-authentication
/org/gnome/login-screen/enable-fingerprint-authentication
/org/gnome/login-screen/enable-password-authentication
/org/gnome/settings-daemon/peripherals/smartcard/removal-action {include if "with-smartcard-lock-on-removal"}
HERE


illinois_write_file /etc/authselect/custom/illinois/sssd/nsswitch.conf <<"HERE"
passwd:     sss files systemd   {exclude if "with-custom-passwd"}
group:      sss files systemd   {exclude if "with-custom-group"}
netgroup:   sss files           {exclude if "with-custom-netgroup"}
automount:  sss files           {exclude if "with-custom-automount"}
services:   sss files           {exclude if "with-custom-services"}
sudoers:    files sss           {include if "with-sudo"}
HERE

illinois_write_file /etc/authselect/custom/illinois/sssd/postlogin <<"HERE"
auth        optional                   pam_ecryptfs.so unwrap                                 {include if "with-ecryptfs"}

password    optional                   pam_ecryptfs.so unwrap                                 {include if "with-ecryptfs"}

session     optional                   pam_umask.so silent
session     [success=1 default=ignore] pam_succeed_if.so service !~ gdm* service !~ su* quiet
session     [default=1]                pam_lastlog.so nowtmp {if "with-silent-lastlog":silent|showfailed}
session     optional                   pam_lastlog.so silent noupdate showfailed
HERE

illinois_write_file /etc/authselect/custom/illinois/sssd/fingerprint-auth <<"HERE"
{continue if "with-fingerprint"}
auth        required                                     pam_env.so
auth        required                                     pam_deny.so # Smartcard authentication is required     {include if "with-smartcard-required"}
auth        required                                     pam_faillock.so preauth silent deny=5 unlock_time=900  {include if "with-faillock"}
auth        [success=done default=bad]                   pam_fprintd.so
auth        required                                     pam_faillock.so authfail deny=5 unlock_time=900        {include if "with-faillock"}
auth        required                                     pam_deny.so

account     required                                     pam_access.so                                          {include if "with-pamaccess"}
account     required                                     pam_faillock.so                                        {include if "with-faillock"}
account     required                                     pam_unix.so
account     sufficient                                   pam_localuser.so                                       {exclude if "with-files-access-provider"}
account     sufficient                                   pam_usertype.so issystem
account     [default=bad success=ok user_unknown=ignore] pam_sss.so
account     required                                     pam_permit.so

password    required                                     pam_deny.so

session     optional                                     pam_keyinit.so revoke
session     required                                     pam_limits.so
session     optional                                     pam_ecryptfs.so unwrap                                {include if "with-ecryptfs"}
-session    optional                                     pam_systemd.so
session     optional                                     pam_oddjob_mkhomedir.so                               {include if "with-mkhomedir"}
session     [success=1 default=ignore]                   pam_succeed_if.so service in crond quiet use_uid
session     required                                     pam_unix.so
session     optional                                     pam_sss.so
HERE

illinois_write_file /etc/authselect/custom/illinois/sssd/password-auth <<"HERE"
auth        required                                     pam_env.so
auth        required                                     pam_faildelay.so delay=2000000
auth        required                                     pam_deny.so # Smartcard authentication is required     {include if "with-smartcard-required"}
auth        required                                     pam_faillock.so preauth silent                         {include if "with-faillock"}
auth        sufficient                                   pam_u2f.so cue                                         {include if "with-pam-u2f"}
auth        required                                     pam_u2f.so cue {if not "without-pam-u2f-nouserok":nouserok} {include if "with-pam-u2f-2fa"}
auth        [default=1 ignore=ignore success=ok]         pam_usertype.so isregular
auth        [default=1 ignore=ignore success=ok]         pam_localuser.so
auth        sufficient                                   pam_unix.so {if not "without-nullok":nullok} try_first_pass
auth        [default=1 ignore=ignore success=ok]         pam_usertype.so isregular
auth        sufficient                                   pam_sss.so forward_pass                                {exclude if "with-duo"}
auth        requisite                                    pam_sss.so forward_pass                                {include if "with-duo"}
auth        sufficient                                   pam_duo.so conf=/etc/duo/pam_duo.conf                  {include if "with-duo"}
auth        required                                     pam_faillock.so authfail                               {include if "with-faillock"}
auth        required                                     pam_deny.so

account     required                                     pam_access.so                                          {include if "with-pamaccess"}
account     required                                     pam_faillock.so                                        {include if "with-faillock"}
account     required                                     pam_unix.so
account     sufficient                                   pam_localuser.so                                       {exclude if "with-files-access-provider"}
account     sufficient                                   pam_usertype.so issystem
account     [default=bad success=ok user_unknown=ignore] pam_sss.so
account     required                                     pam_permit.so

password    requisite                                    pam_pwquality.so try_first_pass local_users_only enforce_for_root retry=3
password    sufficient                                   pam_unix.so sha512 shadow {if not "without-nullok":nullok} try_first_pass use_authtok
password    sufficient                                   pam_sss.so use_authtok
password    required                                     pam_deny.so

session     optional                                     pam_keyinit.so revoke
session     required                                     pam_limits.so
session     optional                                     pam_ecryptfs.so unwrap                                {include if "with-ecryptfs"}
-session    optional                                     pam_systemd.so
session     optional                                     pam_oddjob_mkhomedir.so                               {include if "with-mkhomedir"}
session     [success=1 default=ignore]                   pam_succeed_if.so service in crond quiet use_uid
session     required                                     pam_unix.so
session     optional                                     pam_sss.so
HERE

illinois_write_file /etc/authselect/custom/illinois/sssd/smartcard-auth <<"HERE"
{continue if "with-smartcard"}
auth        required                                     pam_env.so
auth        required                                     pam_faillock.so preauth silent deny=5 unlock_time=900  {include if "with-faillock"}
auth        sufficient                                   pam_sss.so allow_missing_name {if "with-smartcard-required":require_cert_auth}
auth        required                                     pam_faillock.so authfail deny=5 unlock_time=900        {include if "with-faillock"}
auth        required                                     pam_deny.so

account     required                                     pam_access.so                                          {include if "with-pamaccess"}
account     required                                     pam_faillock.so                                        {include if "with-faillock"}
account     required                                     pam_unix.so
account     sufficient                                   pam_localuser.so                                       {exclude if "with-files-access-provider"}
account     sufficient                                   pam_usertype.so issystem
account     [default=bad success=ok user_unknown=ignore] pam_sss.so
account     required                                     pam_permit.so

session     optional                                     pam_keyinit.so revoke
session     required                                     pam_limits.so
session     optional                                     pam_ecryptfs.so unwrap                                 {include if "with-ecryptfs"}
-session     optional                                    pam_systemd.so
session     optional                                     pam_oddjob_mkhomedir.so                                {include if "with-mkhomedir"}
session     [success=1 default=ignore]                   pam_succeed_if.so service in crond quiet use_uid
session     required                                     pam_unix.so
session     optional                                     pam_sss.so
HERE

illinois_write_file /etc/authselect/custom/illinois/sssd/system-auth <<"HERE"
{imply "with-smartcard" if "with-smartcard-required"}
auth        required                                     pam_env.so
auth        required                                     pam_faildelay.so delay=2000000
auth        required                                     pam_faillock.so preauth silent                         {include if "with-faillock"}
auth        [success=1 default=ignore]                   pam_succeed_if.so service notin login:gdm:xdm:kdm:xscreensaver:gnome-screensaver:kscreensaver quiet use_uid {include if "with-smartcard-required"}
auth        [success=done ignore=ignore default=die]     pam_sss.so require_cert_auth ignore_authinfo_unavail   {include if "with-smartcard-required"}
auth        sufficient                                   pam_fprintd.so                                         {include if "with-fingerprint"}
auth        sufficient                                   pam_u2f.so cue                                         {include if "with-pam-u2f"}
auth        required                                     pam_u2f.so cue {if not "without-pam-u2f-nouserok":nouserok} {include if "with-pam-u2f-2fa"}
auth        [default=1 ignore=ignore success=ok]         pam_usertype.so isregular
auth        [default=1 ignore=ignore success=ok]         pam_localuser.so                                       {exclude if "with-smartcard"}
auth        [default=2 ignore=ignore success=ok]         pam_localuser.so                                       {include if "with-smartcard"}
auth        [success=done authinfo_unavail=ignore ignore=ignore default=die] pam_sss.so try_cert_auth           {include if "with-smartcard"}
auth        sufficient                                   pam_unix.so {if not "without-nullok":nullok} try_first_pass
auth        [default=1 ignore=ignore success=ok]         pam_usertype.so isregular
auth        sufficient                                   pam_sss.so forward_pass                                {exclude if "with-duo"}
auth        requisite                                    pam_sss.so forward_pass                                {include if "with-duo"}
auth        sufficient                                   pam_duo.so conf=/etc/duo/pam_duo.conf                  {include if "with-duo"}
auth        required                                     pam_faillock.so authfail                               {include if "with-faillock"}
auth        required                                     pam_deny.so

account     required                                     pam_access.so                                          {include if "with-pamaccess"}
account     required                                     pam_faillock.so                                        {include if "with-faillock"}
account     required                                     pam_unix.so
account     sufficient                                   pam_localuser.so                                       {exclude if "with-files-access-provider"}
account     sufficient                                   pam_usertype.so issystem
account     [default=bad success=ok user_unknown=ignore] pam_sss.so
account     required                                     pam_permit.so

password    requisite                                    pam_pwquality.so try_first_pass local_users_only enforce_for_root retry=3
password    requisite                                    pam_pwhistory.so remember=5 use_authtok
password    sufficient                                   pam_unix.so sha512 shadow {if not "without-nullok":nullok} try_first_pass use_authtok
password    sufficient                                   pam_sss.so use_authtok
password    required                                     pam_deny.so

session     optional                                     pam_keyinit.so revoke
session     required                                     pam_limits.so
session     optional                                     pam_ecryptfs.so unwrap                                {include if "with-ecryptfs"}
-session    optional                                     pam_systemd.so
session     optional                                     pam_oddjob_mkhomedir.so                               {include if "with-mkhomedir"}
session     [success=1 default=ignore]                   pam_succeed_if.so service in crond quiet use_uid
session     required                                     pam_unix.so
session     optional                                     pam_sss.so
HERE

illinois_log "configuring system authentication"
authselect select custom/illinois/sssd with-faillock with-mkhomedir --force

illinois_log "enabling and start sssd"
systemctl enable sssd
systemctl restart sssd
systemctl enable --now oddjobd

illinois_log "hacking ec2-instance-connect to fix sshd_config"
illinois_write_file /usr/local/bin/illinois-fix-eic root:root 0700 << "EOF"
#!/bin/bash

AUTH_KEYS_CMD="AuthorizedKeysCommand /opt/aws/bin/eic_run_authorized_keys %u %f"
AUTH_KEYS_USR="AuthorizedKeysCommandUser ec2-instance-connect"

tmpfiles=()
finish () {
    set +e
    for f in "${tmpfiles[@]}"; do
        rm -fr -- "$f"
    done
}
trap finish EXIT

cfg_file=$(mktemp -t sshd_config.XXXXXXXX); tmpfiles+=("$cfg_file")
cp /etc/ssh/sshd_config "$cfg_file"

cfg_main="$(sed -re '/^\s*Match\s+/Q' "$cfg_file")"

restart_sshd=no
if ! echo "$cfg_main" | egrep -q '^\s*AuthorizedKeysCommand\s+'; then
    if ! echo "$cfg_main" | egrep -q '^\s*AuthorizedKeysCommandUser\s+'; then
        logger --tag illinois-fix-eic --priority local3.info --stderr -- "adding $AUTH_KEYS_USR"
        sed -i -re "/^\s*# Example of overriding settings on a per-user basis/i $AUTH_KEYS_USR" "$cfg_file"
    fi

    logger --tag illinois-fix-eic --priority local3.info --stderr -- "adding $AUTH_KEYS_CMD"
    sed -i -re "/^\s*# Example of overriding settings on a per-user basis/i $AUTH_KEYS_CMD" "$cfg_file"
    restart_sshd=yes
fi

if [[ $restart_sshd = "yes" ]]; then
    if ! sshd -t -f "$cfg_file"; then
        logger --tag illinois-fix-eic --priority local3.err --stderr --  "unable to validate sshd_config"
        exit 1
    fi
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.illinois-fix-eic
    cp "$cfg_file" /etc/ssh/sshd_config
    chown root:root /etc/ssh/sshd_config
    chmod 0600 /etc/ssh/sshd_config

    logger --tag illinois-fix-eic --priority local3.info --stderr -- "restarting sshd"
    systemctl restart sshd
fi
EOF
illinois_write_file /etc/dnf/plugins/post-transaction-actions.d/illinois-fix-eic.action << EOF
ec2-instance-connect:in:/usr/local/bin/illinois-fix-eic
EOF

illinois_log "configuring sshd for using sss authorized keys"
illinois_write_sshd_config /etc/ssh/sshd_config.d/01-illinois-sss.conf <<EOF
Match Group "domain users"
    AuthorizedKeysCommandUser   nobody
    AuthorizedKeysCommand       /usr/bin/sss_ssh_authorizedkeys
EOF

if [[ -n $sss_admin_groups ]]; then
    illinois_log "setting sudo admin groups"
    illinois_write_sudo_config /etc/sudoers.d/illinois <<EOF
User_Alias ILLINOIS_ADMINS = ${sss_admin_groups}
ILLINOIS_ADMINS  ALL=(ALL) NOPASSWD: ALL
EOF
fi

illinois_init_status finished
date > /var/lib/illinois-sss-init
