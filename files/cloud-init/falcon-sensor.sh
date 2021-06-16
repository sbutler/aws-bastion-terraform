#!/bin/bash

# Setup falcon-sensor by downloading it from an S3 bucket and configuring it
# with the customer key in SSM Parameter Store. Options available in
# /etc/opt/illinois/cloud-init/falcon-sensor.conf:
#
#   falcon_sensor_package: S3 URL to where to download the rpm from.
#   falcon_sensor_cid_path: SSM Parameter Path to the CID for the falcon-sensor

set -e

[[ -e /var/lib/illinois-falcon-sensor-init ]] && exit 0
. /etc/opt/illinois/cloud-init/init.sh

[[ -e /etc/opt/illinois/cloud-init/falcon-sensor.conf ]] && . /etc/opt/illinois/cloud-init/falcon-sensor.conf

illinois_init_status falcon-sensor running

if [[ -z $falcon_sensor_package ]]; then
    echo "INFO: no falcon_sensor_package specified; skipping"

    illinois_init_status falcon-sensor finished
    date > /var/lib/illinois-falcon-sensor-init

    exit 0
fi


falcon_sensor_rpm=$(mktemp -t falcon-sensor.XXXXXXXXXX.rpm); tmpfiles+=("$falcon_sensor_rpm")
echo "INFO: getting the falcon-sensor from $falcon_sensor_package"
aws s3 cp $falcon_sensor_package "$falcon_sensor_rpm"

echo "INFO: getting the falcon-sensor CID from $falcon_sensor_cid_path"
falcon_sensor_cid=$(aws ssm get-parameter --with-decryption --name "$falcon_sensor_cid_path" --output text --query Parameter.Value)
if [[ -z $falcon_sensor_cid ]]; then
    echo "ERROR: no value for $falcon_sensor_cid"
    exit 1
fi

echo "INFO: installing falcon-sensor package"
yum install -y "$falcon_sensor_rpm"

echo "INFO: configuring falcon-sensor CID"
/opt/CrowdStrike/falconctl -s --cid="$falcon_sensor_cid"

echo "INFO: starting the falcon-sensor"
systemctl start falcon-sensor

illinois_init_status falcon-sensor finished
date > /var/lib/illinois-falcon-sensor-init
