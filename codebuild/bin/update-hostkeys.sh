#!/bin/bash
set -e

# Generate some new ssh hostkeys and make sure that in parameter store there
# exists a file for it.
#
#   $1: used to set the parameter store values we're looking at

project="$1"
if [[ -z $project ]]; then
    echo "ERROR: no project as command line argument"
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

echo "INFO: generating SSH hostkeys"
ssh-keygen -A -f "$keysdir"
# We don't need the pub files
rm -f "$keysdir/etc/ssh/*.pub"

echo "INFO: getting the names of host key files"
readarray -t param_keys < <(aws ssm describe-parameters \
    --parameter-filters Key=Path,Values="/$project/ssh/" \
    --output text --query 'join(`"\n"`, Parameters[].Name)'
)

cd "$keysdir/etc/ssh"
for f in ssh_host_*_key; do
    param_name="/$project/ssh/$f"
    if [[ ! " ${param_keys[@]} " =~ " $param_name " ]]; then
        echo "INFO: updating host key $param_name"
        aws ssm put-parameter --name "$param_name" \
            --type SecureString \
            --value file://$f
    fi
done
