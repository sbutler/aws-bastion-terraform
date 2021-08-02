#!/bin/bash

# Setup sshd by downloading hostkeys from SSM Parameter Store. Options
# available in /etc/opt/illinois/cloud-init/ssh.conf:
#
#   ssh_hostkeys_path: base path in SSM Parameter Store for host keys. Each
#       item under this path will be created as a key file in  /etc/sshd/.

set -e
ILLINOIS_MODULE=ssh

[[ -e /var/lib/illinois-ssh-init ]] && exit 0
. /etc/opt/illinois/cloud-init/init.sh

[[ -e /etc/opt/illinois/cloud-init/ssh.conf ]] && . /etc/opt/illinois/cloud-init/ssh.conf

if [[ -z $ssh_hostkeys_path ]]; then
    illinois_log err "no ssh_hostkeys_path specified"
    exit 1
fi

illinois_init_status running
cfg_modified=no

illinois_log "getting the names of host key files"
readarray -t ssh_hostkeys_lines < <(aws ssm describe-parameters \
    --parameter-filters Key=Path,Values="$ssh_hostkeys_path" \
    --output text --query 'join(`"\n"`, Parameters[].Name)'
)

for p in "${ssh_hostkeys_lines[@]}"; do
    f="/etc/ssh/$(basename "$p")"
    illinois_log "getting host key $p -> $f"
    if aws ssm get-parameter --with-decryption --name "$p" --output text --query Parameter.Value > "$f"; then
        chmod 0600 "$f"
        illinois_log "creating public key for $f"
        ssh-keygen -y -f "$f" > "$f.pub"

        cfg_modified=yes
    else
        illinois_log err "unable to get $p"
    fi
done

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

cfg_check_value_le () {
    local key="$1"
    local value="$2"
    if [[ -z $cfg_file || -z $cfg_kvseprex || -z $cfg_beforematch ]]; then
        illinois_log err "bad config for cfg_check_value_le"
        exit 2
    fi

    f_value=$(sed -nre "s/^\\s*${key}${cfg_kvseprex}([[:digit:]]+)\\s*(\\s+#.*)?\$/\1/p" "$cfg_file")
    if [[ -z $f_value ]]; then
        illinois_log "$cfg_file - adding $key with $value"
        sed -i -re "${cfg_beforematch}i ${key}${cfg_kvsepstr}${value}" "$cfg_file"
        cfg_modified=yes
    elif (( f_value > value )); then
        illinois_log "$cfg_file - setting $key to $value"
        sed -i -re "s/^\\s*${key}${cfg_kvseprex}[^#]*(\\s+#.*)?\$/${key}${cfg_kvsepstr}${value}\\1/" "$cfg_file"
        cfg_modified=yes
    fi
}

cfg_check_value_ge () {
    local key="$1"
    local value="$2"
    if [[ -z $cfg_file || -z $cfg_kvseprex || -z $cfg_beforematch ]]; then
        illinois_log err "bad config for cfg_check_value_ge"
        exit 2
    fi

    f_value=$(sed -nre "s/^\\s*${key}${cfg_kvseprex}([[:digit:]]+)\\s*(\\s+#.*)?\$/\1/p" "$cfg_file")
    if [[ -z $f_value ]]; then
        illinois_log "$cfg_file - adding $key with $value"
        sed -i -re "${cfg_beforematch}i ${key}${cfg_kvsepstr}${value}" "$cfg_file"
        cfg_modified=yes
    elif (( f_value > value )); then
        illinois_log "$cfg_file - setting $key to $value"
        sed -i -re "s/^\\s*${key}${cfg_kvseprex}[^#]*(\\s+#.*)?\$/${key}${cfg_kvsepstr}${value}\\1/" "$cfg_file"
        cfg_modified=yes
    fi
}

cfg_file=$(mktemp -t sshd_config.XXXXXXXX); tmpfiles+=("$cfg_file")
cp /etc/ssh/sshd_config "$cfg_file"
cfg_kvseprex="\\s+"
cfg_kvsepstr=" "
cfg_beforematch="/^\\s*# Example of overriding settings on a per-user basis/"

cfg_check_value_eq Protocol                 2
cfg_check_value_eq LogLevel                 INFO
cfg_check_value_le MaxAuthTries             4
cfg_check_value_eq IgnoreRhosts             yes
cfg_check_value_eq HostbasedAuthentication  no
cfg_check_value_eq PermitRootLogin          no
cfg_check_value_eq PermitEmptyPasswords     no
cfg_check_value_eq PermitUserEnvironment    no
cfg_check_value_eq Ciphers                  'aes256-ctr,aes192-ctr,aes128-ctr'
cfg_check_value_eq MACs                     'hmac-sha2-512,hmac-sha2-256'
cfg_check_value_eq KexAlgorithms            'curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group14-sha256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512,ecdh-sha2-nistp521,ecdh-sha2-nistp384,ecdh-sha2-nistp256,diffie-hellman-group-exchange-sha256'
cfg_check_value_le ClientAliveInterval      300
cfg_check_value_le ClientAliveCountMax      12
cfg_check_value_le LoginGraceTime           60
cfg_check_value_eq X11Forwarding            yes

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

illinois_init_status finished
date > /var/lib/illinois-ssh-init
