#cloud-boothook

# Setup the cloud-init system we are going to use. This creates a basic library
# of bash functions, make sure some required tools are installed, and installs
# the latest AWS CLI v2.

set -e

[[ -e /etc/opt/illinois/cloud-init/init.sh ]] || cat > /etc/opt/illinois/cloud-init/init.sh << "EOF_INIT"
illinois_log () {
    local _module="${ILLINOIS_MODULE:-$(basename "$0")}"
    local _level="$1"

    if [[ $_level =~ ^(emerg|alert|crit|err|warning|notice|info|debug|panic|error|warn)$ ]]; then
        shift
    else
        _level="info"
    fi

    logger --tag "illinois-init-$_module" --priority "local3.$_level" --stderr -- "$@"
}

tmpfiles=()
illinois_finish () {
    set +e
    local _exitcode=$?

    # Update the status for exit if we've  been sending status updates
    if [[ -n $_illinois_init_status_last ]]; then
        if (( _exitcode == 0 )); then
            illinois_init_status finished
        else
            illinois_init_status error
        fi
    fi

    for f in "${tmpfiles[@]}"; do
        rm -fr "$f"
    done
}
trap illinois_finish EXIT

_illinois_aws_token=""
_illinois_aws_tokenexpires=0
illinois_aws_token () {
    if [[ -z $_illinois_aws_token || $_illinois_aws_tokenexpires -le $(date +%s) ]]; then
        illinois_log "getting IMDS Token"
        _imds_token=$(curl --silent --fail --retry 30 --retry-delay 1 --retry-max-time 30 -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 300" http://169.254.169.254/latest/api/token)
        _imds_exitcode=$?

        if (( _imds_exitcode > 0 )); then
            illinois_log err "unable to get the IMDS Token (code: $_imds_exitcode)"
            return $_imds_exitcode
        fi

       _illinois_aws_token=$_imds_token
       _illinois_aws_tokenexpires=$(( $(date +%s) + 300 ))
    fi

    echo $_illinois_aws_token
    return 0
}
illinois_aws_token >/dev/null

illinois_aws_metadata () {
    local _imds_token=$(illinois_aws_token)
    curl --silent --fail --retry 3 -H "X-aws-ec2-metadata-token: ${_imds_token}" http://169.254.169.254/latest/meta-data/$1
}
instance_id=$(illinois_aws_metadata instance-id)

declare -A _illinois_init_status_last
illinois_init_status () {
    local _module="${ILLINOIS_MODULE:-$(basename "$0")}"
    local _status="$1"
    local _lastStatus="${_illinois_init_status_last[$_module]}"

    # Skip duplicate status updates, or status updates if we've already finished
    if [[ $_lastStatus = $_status || $_lastStatus =~ ^(finished|error)$ ]]; then
        return 0
    fi

    set +e
    local _statustmp=$(mktemp -t illinois-init-status.XXXXXXXXXX); tmpfiles+=("$_statustmp")
    (
        flock -x 200

        if [[ ! -e /var/lib/illinois-init-status.json ]]; then
            [[ -e /etc/opt/illinois/cloud-init/asg.conf ]] && . /etc/opt/illinois/cloud-init/asg.conf
            cat > /var/lib/illinois-init-status.json <<EOF
{
    "Source": "bastion.aws.illinois.edu",
    "Resources": [],
    "DetailType": "Bastion Initialization Status",
    "Detail": "{\"autoScalingGroupName\":\"$asg_name\",\"instanceID\":\"$instance_id\",\"status\":{}}"
}
EOF
        fi

        if jq --arg m "$_module" --arg v "$_status" '.Detail = (.Detail | fromjson | .status[$m] = $v | .lastStatus = $m | tojson)' < /var/lib/illinois-init-status.json > "$_statustmp"; then
            cp "$_statustmp" /var/lib/illinois-init-status.json
            local _eventID="$(aws events put-events --entries "[$(cat /var/lib/illinois-init-status.json)]" --output text --query 'Entries[0].EventId')"
            illinois_log "updated status to $_status (event: $_eventID)"
        else
            illinois_log err "unable to update illinois-init-status.json"
        fi
    ) 200> /var/lock/illinois-init-status
    set -e

    _illinois_init_status_last[$_module]="$_status"
}

illinois_rpm_install () {
    local pkg
    for pkg in "$@"; do
        if ! rpm -q --quiet $pkg; then
            local _yum_maxwait=40
            while [[ -e /var/run/yum.pid && $_yum_maxwait -gt 0 ]] && kill -CHLD $(</var/run/yum.pid); do
                illinois_log "Waiting for another yum process..."
                sleep 5
                (( _yum_maxwait-- )) || :
            done

            yum -y install $pkg
        fi
    done
}

illinois_rpm_remove () {
    local pkg
    for pkg in "$@"; do
        if rpm -q --quiet $pkg; then
            local _yum_maxwait=40
            while [[ -e /var/run/yum.pid && $_yum_maxwait -gt 0 ]] && kill -CHLD $(</var/run/yum.pid); do
                illinois_log "Waiting for another yum process..."
                sleep 5
                (( _yum_maxwait-- )) || :
            done

            yum -y remove $pkg
        fi
    done
}

illinois_get_param () {
    local _param="$1"

    if ! aws ssm get-parameter --with-decryption --name "$_param" --output text --query Parameter.Value; then
        local _exitcode=$?
        if [[ $# -gt 1 ]]; then
            echo "$2"
        else
            return $_exitcode
        fi
    fi
}

illinois_get_listparam () {
    local _data="$(illinois_get_param "$@")"

    local -a _arr=()
    IFS=,
    read -ra _arr <<< "$_data"
    unset IFS

    # Strip out blank lines and echo back to stdout for readarray
    for a in "${_arr[@]}"; do
        if [[ -n $a ]]; then
            echo "$a"
        fi
    done
}
EOF_INIT

ILLINOIS_MODULE=awscli
[[ -e /var/lib/illinois-awscli-init ]] && exit 0
. /etc/opt/illinois/cloud-init/init.sh

illinois_rpm_install jq
illinois_rpm_remove awscli

illinois_init_status running

cd /tmp
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
./aws/install
rm -fr awscliv2.zip aws

aws configure set default.region $(illinois_aws_metadata placement/region)
aws configure set s3.signature_version s3v4

illinois_init_status finished
date > /var/lib/illinois-awscli-init
