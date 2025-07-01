#!/bin/bash

# Setup duo by downloading keys from SSM Parameter Store. This will configure
# Duo to prompt for all domain users using a password (SSH pubkey is not
# prompted).
#
# Warning: only run this after `sss.sh` or `cis.sh`. It depends on configuration
# performed in those scripts.
#
# /etc/opt/illinois/cloud-init/duo.conf:
#
#   duo_ikey_parameter: SSM Parameter path for the integration key.
#   duo_skey_parameter: SSM Parameter path for the secret key.
#   duo_host_parameter: SSM Parameter path for the hostname.
#   duo_groups: List of space separated groups to enable Duo for.

set -e
ILLINOIS_MODULE=duo

[[ $ILLINOIS_FORCE =~ ^(n|no|f|false|0)?$ && -e /var/lib/illinois-duo-init ]] && exit 0
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

illinois_log "adding duo repository"
illinois_write_file etc/yum.repos.d/duosecurity.repo <<"HERE"
[duosecurity]
name=Duo Security Repository
baseurl=https://pkg.duosecurity.com/AmazonLinux/2023/$basearch
enabled=1
gpgcheck=1
HERE
rpm --import https://duo.com/DUO-GPG-PUBLIC-KEY.asc

illinois_log "installing duo_unix"
illinois_rpm_install duo_unix

[[ -e /etc/duo ]] || mkdir /etc/duo

illinois_log "writing /etc/duo/pam_duo.conf"
illinois_write_file /etc/duo/pam_duo.conf root:root 0600 <<HERE
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

illinois_write_sshd_config /etc/ssh/sshd_config.d/01-illinois-duo.conf <<EOF
UsePAM yes
UseDNS no

PasswordAuthentication          yes
ChallengeResponseAuthentication yes
EOF

authselect enable-feature with-duo

illinois_init_status finished
date > /var/lib/illinois-duo-init
