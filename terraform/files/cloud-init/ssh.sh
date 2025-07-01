#!/bin/bash

# Setup sshd by downloading hostkeys from SSM Parameter Store and adding basic
# security settings.
#
# /etc/opt/illinois/cloud-init/ssh.conf:
#
#   ssh_hostkeys_path: base path in SSM Parameter Store for host keys. Each
#       item under this path will be created as a key file in  /etc/sshd/.
#   ssh_client_alive_interval: how often sshd will check that a client is alive.
#   ssh_client_alive_count_max: how many idle checks before a client is
#       disconnected.
#   ssh_allow_groups: array of groups that are allowed to login. The group
#       "wheel" will always be added if not specified. Default is "wheel" and
#       "domain users".

set -e
ILLINOIS_MODULE=ssh

[[ $ILLINOIS_FORCE =~ ^(n|no|f|false|0)?$ && -e /var/lib/illinois-ssh-init ]] && exit 0
. /etc/opt/illinois/cloud-init/init.sh

[[ -e /etc/opt/illinois/cloud-init/ssh.conf ]] && . /etc/opt/illinois/cloud-init/ssh.conf

: ${ssh_client_alive_interval:=60}
: ${ssh_client_alive_count_max:=5}

if [[ $ssh_client_alive_interval -le 0 || ssh_client_alive_count_max -lt 0 ]]; then
    ssh_client_alive_interval=60
    ssh_client_alive_count_max=5
fi

declare -a ssh_allow_groups
[[ ${#ssh_allow_groups[@]} -gt 0 ]] || ssh_allow_groups=(wheel "domain users")

# Loop through the groups, adding quotes if there are spaces and ensuring that
# "wheel" is included.
declare -a _ssh_allow_groups=()
_ssh_allow_groups_has_wheel=no
for _group in "${ssh_allow_groups[@]}"; do
    if [[ $_group = wheel ]]; then
        _ssh_allow_groups_has_wheel=yes
    fi

    if [[ $_group == *" "* ]]; then
        _ssh_allow_groups+=("\"$_group\"")
    else
        _ssh_allow_groups+=("$_group")
    fi
done
if [[ $_ssh_allow_groups_has_wheel = no ]]; then
    _ssh_allow_groups+=("wheel")
fi


illinois_init_status running

if [[ -n $ssh_hostkeys_path ]]; then
    illinois_log "getting the names of host key files"
    readarray -t ssh_hostkeys_lines < <(aws ssm describe-parameters \
        --parameter-filters Key=Path,Values="$ssh_hostkeys_path" \
        --output text --query 'join(`"\n"`, Parameters[].Name)'
    )

    for p in "${ssh_hostkeys_lines[@]}"; do
        f="/etc/ssh/$(basename "$p")"
        illinois_log "getting host key $p -> $f"
        if aws ssm get-parameter --with-decryption --name "$p" --output text --query Parameter.Value > "$f"; then
            chown root:root "$f"
            chmod 0600 "$f"

            illinois_log "creating public key for $f"
            ssh-keygen -y -f "$f" > "$f.pub"

            cfg_modified=yes
        else
            illinois_log err "unable to get $p"
        fi
    done
fi

illinois_log "configuring sshd"
illinois_write_sshd_config /etc/ssh/sshd_config.d/00-illinois.conf <<EOF
Banner                   /etc/issue.net
Protocol                 2
LogLevel                 INFO
MaxStartups              10:30:60
MaxAuthTries             4
LoginGraceTime           60

IgnoreRhosts             yes
HostbasedAuthentication  no
PermitRootLogin          no
PermitEmptyPasswords     no
PermitUserEnvironment    no
X11Forwarding            yes

Ciphers                  'aes256-ctr,aes192-ctr,aes128-ctr'
MACs                     'hmac-sha2-512,hmac-sha2-256'
KexAlgorithms            'curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group14-sha256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512,ecdh-sha2-nistp521,ecdh-sha2-nistp384,ecdh-sha2-nistp256,diffie-hellman-group-exchange-sha256'

TCPKeepAlive             yes
ClientAliveInterval      $ssh_client_alive_interval
ClientAliveCountMax      $ssh_client_alive_count_max

AllowGroups              ${_ssh_allow_groups[@]}
EOF

illinois_init_status finished
date > /var/lib/illinois-ssh-init
