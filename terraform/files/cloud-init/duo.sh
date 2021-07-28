#!/bin/bash

# Setup duo by downloading keys from SSM Parameter Store. Options
# available in /etc/opt/illinois/cloud-init/duo.conf:
#
#   duo_ikey_parameter: SSM Parameter Store path for the integration key.
#   duo_skey_parameter: SSM Parameter Store path for the secret key.
#   duo_host_parameter: SSM Parameter Store path for the hostname.
#   duo_groups: List of space separated groups to enable Duo for

set -e
ILLINOIS_MODULE=duo

[[ -e /var/lib/illinois-duo-init ]] && exit 0
. /etc/opt/illinois/cloud-init/init.sh

[[ -e /etc/opt/illinois/cloud-init/duo.conf ]] && . /etc/opt/illinois/cloud-init/duo.conf

if [[ -z $duo_ikey_parameter ]]; then
    illinois_log err "no duo_ikey_parameter specified"
    exit 1
fi
if [[ -z $duo_skey_parameter ]]; then
    illinois_log err "no duo_skey_parameter specified"
    exit 1
fi
if [[ -z $duo_host_parameter ]]; then
    illinois_log err "no duo_host_parameter specified"
    exit 1
fi

: ${duo_groups:='domain?users'}

illinois_init_status running

illinois_log "getting ikey from SSM $duo_ikey_parameter"
duo_ikey="$(illinois_get_param "$duo_ikey_parameter" "")"
illinois_log "getting skey from SSM $duo_skey_parameter"
duo_skey="$(illinois_get_param "$duo_skey_parameter" "")"
illinois_log "getting host from SSM $duo_host_parameter"
duo_host="$(illinois_get_param "$duo_host_parameter" "")"

if [[ -z $duo_ikey || -z $duo_skey || -z $duo_host ]]; then
    illinois_log warn "not configured; skipping"

    illinois_init_status finished
    date > /var/lib/illinois-duo-init

    exit 0
fi

_builddir="$(mktemp -d duo-build-XXXXXXXX.d)"; tmpfiles+=("$_builddir")
cd "$_builddir"

illinois_log "downloading source code"
curl --silent --fail https://dl.duosecurity.com/duo_unix-latest.tar.gz > duo_unix.tar.gz

illinois_log "unpacking source code"
mkdir src
tar --strip-components=1 -C src -zxvf duo_unix.tar.gz
chown -R nobody: src
cd src

illinois_log "building source code"
runuser -u nobody -- ./configure --with-pam --prefix=/usr
runuser -u nobody -- make

illinois_log "installing pam_duo"
make install

illinois_log "writing /etc/duo/pam_duo.conf"
cat > /etc/duo/pam_duo.conf <<HERE
[duo]
; Duo integration key
ikey=${duo_ikey}
; Duo secret key
skey=${duo_skey}
; Duo API host
host=${duo_host}
; 'failmode = safe' In the event of errors with this configuration file or connection to the Duo service
; this mode will allow login without 2FA.
; 'failmode = secure' This mode will deny access in the above cases. Misconfigurations with this setting
; enabled may result in you being locked out of your system.
failmode=safe
; Send command for Duo Push authentication
;pushinfo = yes
autopush=yes
prompts=1
groups=${duo_groups}
HERE
chown root:root /etc/duo/pam_duo.conf
chmod u=rw,g=,o= /etc/duo/pam_duo.conf

cfg_check_value_eq () {
    local key="$1"
    local value="$2"
    if [[ -z $cfg_file || -z $cfg_kvseprex || -z $cfg_beforematch ]]; then
        illinois_log err "bad config for cfg_check_value_eq"
        exit 2
    fi

    if ! egrep -q "^\\s*${key}${cfg_kvseprex}${value}\\s*(\\s+#.*)?\$" "$cfg_file"; then
        illinois_log "$cfg_file - setting $key to $value"
        if egrep -q "^\\s*${key}${cfg_kvseprex}" "$cfg_file"; then
            sed -i -re "s/^\\s*${key}${cfg_kvseprex}[^#]*(\\s+#.*)?\$/${key}${cfg_kvsepstr}${value}\\1/" "$cfg_file"
        else
            sed -i -re "${cfg_beforematch}i ${key}${cfg_kvsepstr}${value}" "$cfg_file"
        fi
        cfg_modified=yes
    fi
}

cfg_file=$(mktemp -t sshd_config.XXXXXXXX); tmpfiles+=("$cfg_file")
cp /etc/ssh/sshd_config "$cfg_file"
cfg_kvseprex="\\s+"
cfg_kvsepstr=" "
cfg_beforematch="/^\\s*# Example of overriding settings on a per-user basis/"
cfg_modified=no

cfg_check_value_eq UsePAM yes
cfg_check_value_eq ChallengeResponseAuthentication yes
cfg_check_value_eq UseDNS no
if [[ $cfg_modified = "yes" ]]; then
    if ! sshd -t -f "$cfg_file"; then
        illinois_log err "unable to validate sshd_config"
        exit 1
    fi
    cp "$cfg_file" /etc/ssh/sshd_config
    chown root:root /etc/ssh/sshd_config
    chmod 0600 /etc/ssh/sshd_config

    illinois_log "restarting sshd"
    systemctl restart sshd
fi

pam_cfg_file=/etc/pam.d/system-auth
if ! egrep -q 'auth.+pam_duo.so' $pam_cfg_file; then
    if [[ -h $pam_cfg_file ]]; then
        if [[ ! -e "${pam_cfg_file}-illinois" ]]; then
            illinois_log "creating ${pam_cfg_file}-illinois"
            cp "$pam_cfg_file" "${pam_cfg_file}-illinois"

            rm "$pam_cfg_file"
            ln -s "$(basename "${pam_cfg_file}")-illinois" "$pam_cfg_file"
        fi
        pam_cfg_file="${pam_cfg_file}-illinois"
    fi

    illinois_log "adding pam_duo after pam_sss"
    sed -i -re 's/^(auth\s+)(\S+)\s+(pam_sss\.so.*)$/#\0\n\1requisite \3\n\1\2 pam_duo.so/' "$pam_cfg_file"
fi

illinois_init_status finished
date > /var/lib/illinois-duo-init
