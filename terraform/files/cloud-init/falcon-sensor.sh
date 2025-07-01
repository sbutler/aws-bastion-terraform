#!/bin/bash

# Setup falcon-sensor by downloading it from an S3 bucket and configuring it
# with the customer key in SSM Parameter Store.
#
# /etc/opt/illinois/cloud-init/falcon-sensor.conf:
#
#   falcon_sensor_package: S3 URL to where to download the rpm from.
#   falcon_sensor_cid_path: SSM Parameter Path to the CID for the falcon-sensor

set -e
ILLINOIS_MODULE=falcon-sensor

[[ $ILLINOIS_FORCE =~ ^(n|no|f|false|0)?$ && -e /var/lib/illinois-falcon-sensor-init ]] && exit 0
. /etc/opt/illinois/cloud-init/init.sh

[[ -e /etc/opt/illinois/cloud-init/falcon-sensor.conf ]] && . /etc/opt/illinois/cloud-init/falcon-sensor.conf

illinois_init_status running

if [[ -z $falcon_sensor_package ]]; then
    illinois_log "no falcon_sensor_package specified; skipping"

    illinois_init_status finished
    date > /var/lib/illinois-falcon-sensor-init

    exit 0
fi


falcon_sensor_rpm=$(mktemp -t falcon-sensor.XXXXXXXXXX.rpm); tmpfiles+=("$falcon_sensor_rpm")
illinois_log "getting the falcon-sensor from $falcon_sensor_package"
aws s3 cp $falcon_sensor_package "$falcon_sensor_rpm" --quiet

illinois_log "getting the falcon-sensor CID from $falcon_sensor_cid_path"
falcon_sensor_cid="$(illinois_get_param "$falcon_sensor_cid_path")"
if [[ -z $falcon_sensor_cid ]]; then
    illinois_log err "no value for $falcon_sensor_cid"
    exit 1
fi

illinois_log "installing falcon-sensor package"
dnf install -y "$falcon_sensor_rpm"

illinois_log "configuring falcon-sensor CID"
/opt/CrowdStrike/falconctl -s --cid="$falcon_sensor_cid"

illinois_log "starting the falcon-sensor"
systemctl enable --now falcon-sensor

illinois_init_status finished
date > /var/lib/illinois-falcon-sensor-init
