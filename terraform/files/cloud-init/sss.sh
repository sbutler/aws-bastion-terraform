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
ILLINOIS_MODULE=sss

[[ -e /var/lib/illinois-sss-init ]] && exit 0
. /etc/opt/illinois/cloud-init/init.sh

[[ -e /etc/opt/illinois/cloud-init/sss.conf ]] && . /etc/opt/illinois/cloud-init/sss.conf

: ${sss_admin_groups:=""}
: ${sss_allow_groups:="domain users"}
: ${sss_override_homedir:="/home/%d/%u"}

if [[ -z $sss_binduser_parameter ]]; then
    illinois_log err "no sss_binduser_parameter specified"
    exit 1
fi
if [[ -z $sss_bindpass_parameter ]]; then
    illinois_log err "no sss_bindpass_parameter specified"
    exit 1
fi
if [[ -z $sss_admingroups_parameter ]]; then
    illinois_log err "no sss_admingroups_parameter specified"
    exit 1
fi
if [[ -z $sss_allowgroups_parameter ]]; then
    illinois_log err "no sss_allowgroups_parameter specified"
    exit 1
fi

illinois_init_status running

illinois_log "getting bind username from SSM $sss_binduser_parameter"
bindcreds_user="$(illinois_get_param "$sss_binduser_parameter")"
illinois_log "getting bind password from SSM $sss_bindpass_parameter"
bindcreds_pass="$(illinois_get_param "$sss_bindpass_parameter")"

illinois_log "getting the admin groups from SSM $sss_admingroups_parameter"
readarray -t _sss_admin_groups <<<  "$(illinois_get_listparam "$sss_admingroups_parameter")"
illinois_log "getting the admin groups from SSM $sss_allowgroups_parameter"
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

illinois_log "will bind as ${bindcreds_user}"

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

illinois_log "configuring system authentication"
# Run authconfig and then copy its results for our own, so later scripts can
# modify it
authconfig --enablefaillock --faillockargs="deny=5 unlock_time=900" \
    --enablesssd --enablesssdauth \
    --enablemkhomedir \
    --update
for file in password-auth system-auth; do
    pam_cfg_file=/etc/pam.d/$file
    if [[ -h $pam_cfg_file ]]; then
        if [[ ! -e "${pam_cfg_file}-illinois" ]]; then
            illinois_log "creating ${pam_cfg_file}-illinois"
            cp "$pam_cfg_file" "${pam_cfg_file}-illinois"
        fi

        if [[ $(readlink "$pam_cfg_file") != "${file}-illinois" ]]; then
            illinois_log "linking $pam_cfg_file to ${file}-illinois"
            rm "$pam_cfg_file"
            ln -s "${file}-illinois" "$pam_cfg_file"
        fi
    fi

    illinois_log "fixing faillock in ${file}-illinois"
    sed -i.illinois-sss -r \
        -e '/^\s*auth\s+required\s+pam_faildelay\.so/a auth        required      pam_faillock.so preauth silent deny=5 unlock_time=900' \
        -e '/^\s*auth\s+required\s+pam_deny\.so/i auth        [default=die]      pam_faillock.so authfail deny=5 unlock_time=900' \
        -e '/^\s*auth\s+required\s+pam_faillock\.so/d' \
        "/etc/pam.d/${file}-illinois"
done

illinois_log "enabling and start sssd"
systemctl enable sssd
systemctl restart sssd

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
illinois_write_file /etc/yum/post-actions/illinois-fix-eic.action << EOF
ec2-instance-connect:install:/usr/local/bin/illinois-fix-eic
ec2-instance-connect:update:/usr/local/bin/illinois-fix-eic
EOF

illinois_log "configuring sshd for using sss authorized keys"

cfg_file=$(mktemp -t sshd_config.XXXXXXXX); tmpfiles+=("$cfg_file")
cp /etc/ssh/sshd_config "$cfg_file"
restart_sshd=no
if ! egrep -q '^\s*# ADDED BY SSS CONFIGURATION' "$cfg_file"; then
    illinois_log "adding sss authorized keys for domain users"
    cat >> "$cfg_file" <<EOF

# ADDED BY SSS CONFIGURATION
Match Group "domain users"
    AuthorizedKeysCommandUser nobody
    AuthorizedKeysCommand /usr/bin/sss_ssh_authorizedkeys
EOF
    restart_sshd=yes
fi

if [[ $restart_sshd = "yes" ]]; then
    if ! sshd -t -f "$cfg_file"; then
        illinois_log err "unable to validate sshd_config"
        exit 1
    fi
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.illinois-sss
    cp "$cfg_file" /etc/ssh/sshd_config
    chown root:root /etc/ssh/sshd_config
    chmod 0600 /etc/ssh/sshd_config

    illinois_log "restarting sshd"
    systemctl restart sshd
fi

if [[ -n $sss_admin_groups ]]; then
    illinois_log "setting sudo admin groups"
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
        illinois_log err "unable to validate illinois sudoers file"
        exit 1
    fi
fi

illinois_init_status finished
date > /var/lib/illinois-sss-init
