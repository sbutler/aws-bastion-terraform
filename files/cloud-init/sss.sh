#!/bin/bash

# Setup sssd to connect to ad.uillinois.edu and use uiucEduSSHPublicKey for
# the authorized keys. It will also setup sudo access for members of an admin
# group. Options for /etc/opt/illinois/cloud-init/sss.conf:
#
#   sss_binduser_parameter: SSM Parameter Store path for the username to bind as.
#   sss_bindpass_parameter: SSM Parameter Store path for the password to bind as.
#   sss_admin_groups: list of UOFI groups with admin access (sudo format).
#   sss_allow_groups: list of UOFI groups with shell access (sssd.conf format).
#   sss_override_homedir: where the UOFI user homedir should be.
#   sss_override_gid: primary GID to override.

set -e

[[ -e /var/lib/illinois-sss-init ]] && exit 0
. /etc/opt/illinois/cloud-init/init.sh

[[ -e /etc/opt/illinois/cloud-init/sss.conf ]] && . /etc/opt/illinois/cloud-init/sss.conf

: ${sss_admin_groups:=""}
: ${sss_allow_groups:="domain users"}
: ${sss_override_homedir:="/home/%d/%u"}

if [[ -z $sss_binduser_parameter ]]; then
    echo "ERROR: no sss_binduser_parameter specified"
    exit 1
fi
if [[ -z $sss_bindpass_parameter ]]; then
    echo "ERROR: no sss_bindpass_parameter specified"
    exit 1
fi
if [[ -z $sss_admingroups_parameter ]]; then
    echo "ERROR: no sss_admingroups_parameter specified"
    exit 1
fi
if [[ -z $sss_allowgroups_parameter ]]; then
    echo "ERROR: no sss_allowgroups_parameter specified"
    exit 1
fi

illinois_rpm_install sssd sudo

illinois_init_status sss running

echo "INFO: getting bind username from SSM $sss_binduser_parameter"
bindcreds_user="$(illinois_get_param "$sss_binduser_parameter")"
echo "INFO: getting bind password from SSM $sss_bindpass_parameter"
bindcreds_pass="$(illinois_get_param "$sss_bindpass_parameter")"

echo "INFO: getting the admin groups from SSM $sss_admingroups_parameter"
readarray -t _sss_admin_groups <<<  "$(illinois_get_listparam "$sss_admingroups_parameter")"
echo "INFO: getting the admin groups from SSM $sss_allowgroups_parameter"
readarray -t _sss_allow_groups <<< "$(illinois_get_listparam "$sss_allowgroups_parameter" "")"
_sss_allow_groups+=("${_sss_admin_groups[@]}")

IFS=$'\n'
_sss_admin_groups=($(sort -u <<< "${_sss_admin_groups[*]}"))
_sss_allow_groups=($(sort -u <<< "${_sss_allow_groups[*]}"))
unset IFS

for i in ${!_sss_admin_groups[@]}; do
    _sss_admin_groups[$i]="\"%${_sss_admin_groups[$i]}\""
done
sss_admin_groups=$(IFS=,; echo "${_sss_admin_groups[*]}")
sss_allow_groups=$(IFS=,; echo "${_sss_allow_groups[*]}")

echo "INFO: will bind as ${bindcreds_user}"

cat > /etc/sssd/sssd.conf <<EOF
[sssd]
domains = LOCAL, ad.uillinois.edu
services = nss, pam, ssh
config_file_version = 2

[nss]
filter_groups = root, wheel
filter_users = root, ec2-user

[domain/LOCAL]
id_provider = local
auth_provider = local
access_provider = permit

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

echo "INFO: configuring system authentication"
authconfig --enablesssd --enablesssdauth --enablemkhomedir --update

echo "INFO: enabling and start sssd"
systemctl enable sssd
systemctl restart sssd

echo "INFO: configuring sshd for using sss authorized keys"

cfg_file=$(mktemp -t sshd_config.XXXXXXXX); tmpfiles+=("$cfg_file")
cp /etc/ssh/sshd_config "$cfg_file"
restart_sshd=no
if ! egrep -q '^\s*AuthorizedKeysCommandUser\s+(\S+)' "$cfg_file"; then
    echo "INFO: adding AuthorizedKeysCommandUser nobody"
    sed -re '/^\s*# Example of overriding settings on a per-user basis/i AuthorizedKeysCommandUser nobody' "$cfg_file"
    restart_sshd=yes
fi
if ! egrep -q '^\s*# ADDED BY SSS CONFIGURATION' "$cfg_file"; then
    echo "INFO: adding sss authorized keys for domain users"
    cat >> "$cfg_file" <<EOF

# ADDED BY SSS CONFIGURATION
Match Group "domain users"
    AuthorizedKeysCommand /usr/bin/sss_ssh_authorizedkeys
EOF
    restart_sshd=yes
fi

if [[ $restart_sshd = "yes" ]]; then
    if ! sshd -t -f "$cfg_file"; then
        echo "ERROR: unable to validate sshd_config"
        exit 1
    fi
    cp "$cfg_file" /etc/ssh/sshd_config
    chown root:root /etc/ssh/sshd_config
    chmod 0600 /etc/ssh/sshd_config

    echo "INFO: restarting sshd"
    systemctl restart sshd
fi

if [[ -n $sss_admin_groups ]]; then
    echo "INFO: setting sudo admin groups"
    cfg_file=$(mktemp -t illinois-sudoers.XXXXXXXX); tmpfiles+=("$cfg_file")
    cat > "$cfg_file" <<EOF
User_Alias ILLINOIS_ADMINS = ${sss_admin_groups}
ILLINOIS_ADMINS  ALL=(ALL) NOPASSWD: ALL
EOF

    if visudo -cf "$cfg_file"; then
        cp "$cfg_file" /etc/sudoers.d/illinois
        chown root:root /etc/sudoers.d/illinois
        chmod 0640 /etc/sudoers.d/illinois
    else
        echo "ERROR: unable to validate illinois sudoers file"
        exit 1
    fi
fi

illinois_init_status sss finished
date > /var/lib/illinois-sss-init
