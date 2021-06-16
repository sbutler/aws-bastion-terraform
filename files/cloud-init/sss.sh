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

illinois_rpm_install sssd sudo

illinois_init_status sss running

echo "INFO: getting bind username from SSM $sss_binduser_parameter"
bindcreds_user=$(aws ssm get-parameter --with-decryption --name "$sss_binduser_parameter" --output text --query Parameter.Value)
echo "INFO: getting bind password from SSM $sss_bindpass_parameter"
bindcreds_pass=$(aws ssm get-parameter --with-decryption --name "$sss_bindpass_parameter" --output text --query Parameter.Value)

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
cfg_file=/etc/ssh/sshd_config
restart_sshd=no
if ! egrep -q '^\s*AuthorizedKeysCommandUser\s+(\S+)' "$cfg_file"; then
    echo "INFO: adding AuthorizedKeysCommandUser nobody"
    sed -i.bak-illinois-sss1 -re '/^\s*# Example of overriding settings on a per-user basis/i AuthorizedKeysCommandUser nobody' "$cfg_file"
    restart_sshd=yes
fi
if ! egrep -q '^\s*# ADDED BY SSS CONFIGURATION' "$cfg_file"; then
    echo "INFO: adding sss authorized keys for domain users"
    cp "$cfg_file" "$cfg_file.bak-illinois-sss2"
    cat >> "$cfg_file" <<EOF

# ADDED BY SSS CONFIGURATION
Match Group "domain users"
    AuthorizedKeysCommand /usr/bin/sss_ssh_authorizedkeys
EOF
    restart_sshd=yes
fi

if [[ $restart_sshd = "yes" ]]; then
    echo "INFO: restarting sshd"
    systemctl restart sshd
fi

if [[ -n $sss_admin_groups ]]; then
    echo "INFO: setting sudo admin groups"
    cat > "/etc/sudoers.d/illinois" <<EOF
User_Alias ILLINOIS_ADMINS = ${sss_admin_groups}
ILLINOIS_ADMINS  ALL=(ALL) NOPASSWD: ALL
EOF
    chown root:root /etc/sudoers.d/illinois
    chmod 0640 /etc/sudoers.d/illinois
fi

illinois_init_status sss finished
date > /var/lib/illinois-sss-init
