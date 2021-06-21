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
    echo "ERROR: no ssh_hostkeys_path specified"
    exit 1
fi

illinois_init_status running

echo "INFO: getting the names of host key files"
readarray -t ssh_hostkeys_lines < <(aws ssm describe-parameters \
    --parameter-filters Key=Path,Values="$ssh_hostkeys_path" \
    --output text --query 'join(`"\n"`, Parameters[].Name)'
)

for p in "${ssh_hostkeys_lines[@]}"; do
    f="/etc/ssh/$(basename "$p")"
    echo "INFO: getting host key $p -> $f"
    if aws ssm get-parameter --with-decryption --name "$p" --output text --query Parameter.Value > "$f"; then
        chmod 0600 "$f"
        echo "INFO: creating public key for $f"
        ssh-keygen -y -f "$f" > "$f.pub"
    else
        echo "ERROR: unable to get $p"
    fi
done

echo "INFO: restarting sshd"
if ! sshd -t; then
    echo "ERROR: unable to validate sshd_config"
    exit 1
fi
systemctl restart sshd

illinois_init_status finished
date > /var/lib/illinois-ssh-init
