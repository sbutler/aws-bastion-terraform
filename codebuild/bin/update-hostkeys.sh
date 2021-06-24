#!/bin/bash
set -e

# Generate some new ssh hostkeys and make sure that in parameter store there
# exists a file for it.
#
#   $1: used to set the parameter store values we're looking at
#   $2: hostname for the key comment

project="$1"
if [[ -z $project ]]; then
    echo "ERROR: no project as command line argument"
    exit 1
fi
hostname="$2"
if [[ -z $hostname ]]; then
    echo "ERROR: no hostname as command line argument"
    exit 1
fi

tmpfiles=()
cleanup () {
    for f in "${tmpfiles[@]}"; do
        rm -fr "$f" || :
    done
}
trap cleanup EXIT

keysdir=$(mktemp -t -d update-hostkeys.XXXXXXXX.d); tmpfiles+=("$keysdir")

echo "INFO: getting the names of host key files"
readarray -t param_keys < <(aws ssm describe-parameters \
    --parameter-filters Key=Path,Values="/$project/ssh/" \
    --output text --query 'join(`"\n"`, Parameters[].Name)'
)

for t in rsa dsa ecdsa ed25519; do
    param_name="/$project/ssh/ssh_host_${t}_key"
    if [[ ! " ${param_keys[@]} " =~ " $param_name " ]]; then
        echo "INFO: generating new $t key"
        ssh-keygen -t $t -C "root@$hostname" -N '' -f "$keysdir/$t"
        echo "INFO: updating host key $param_name"
        aws ssm put-parameter --name "$param_name" \
            --type SecureString \
            --value file://$keysdir/$t
    fi
done
