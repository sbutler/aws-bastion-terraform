#!/bin/bash

# Setup CloudWatch Logs Agent and journald logging to CloudWatch Logs. This
# configures a standard set of log files to collect, and also some additional
# metrics. It will also install the `journald-cloudwatch-logs` binary if
# configured to send all systemd logs to CloudWatch Logs.
#
# /etc/opt/illinois/cloud-init/ec2logs.conf:
#
#   loggroup_prefix: Prefix for all log groups.
#   metrics_autoscaling_group: Whether to add the AutoScalingGroupName dimension.
#   metrics_collection_interval: How often to collect metrics.
#   metrics_namespace: CloudWatch namespace for metrics.
#   files_collect_list: Additional files to collect. This is a JSON array that
#       is appended to the existing `logs.logs_collected.files.collect_list` in
#       the config.
#   journald_cloudwatch_logs_package: S3 URL to the journald-cloudwatch-logs. If
#       empty, it will not be installed.

set -e
ILLINOIS_MODULE=ec2logs

[[ $ILLINOIS_FORCE =~ ^(n|no|f|false|0)?$ && -e /var/lib/illinois-ec2logs-init ]] && exit 0
. /etc/opt/illinois/cloud-init/init.sh

[[ -e /etc/opt/illinois/cloud-init/ec2logs.conf ]] && . /etc/opt/illinois/cloud-init/ec2logs.conf

: ${loggroup_prefix=ec2/}
: ${metrics_autoscaling_group:=no}
: ${metrics_collection_interval:=60}
: ${metrics_namespace:=CWAgent}

illinois_init_status running

cwlogs_region="$(illinois_aws_metadata placement/region)"

illinois_log "downloading CWAgent"
rpmfile=$(mktemp -t amazon-cloudwatch-agent.XXXXXXXX.rpm); tmpfiles+=("$rpmfile")
curl --silent --fail --output "$rpmfile" "https://s3.${cwlogs_region}.amazonaws.com/amazoncloudwatch-agent-${cwlogs_region}/amazon_linux/amd64/latest/amazon-cloudwatch-agent.rpm"

illinois_log "installing CWAgent"
dnf -y install "$rpmfile"

cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<HERE
{
    "agent": {
        "metrics_collection_interval": ${metrics_collection_interval},
        "run_as_user": "root",
        "region": "${cwlogs_region}",
        "omit_hostname": true
    },
    "logs": {
        "logs_collected": {
            "files": {
                "collect_list": [
                    {
                        "file_path": "/var/log/audit/audit.log*",
                        "log_group_name": "/${loggroup_prefix}var/log/audit/audit.log",
                        "log_stream_name": "{instance_id}"
                    },
                    {
                        "file_path": "/var/log/cloud-init.log",
                        "timezone": "Local",
                        "timestamp_format": "%Y-%m-%dT%H:%M:%S.%f",
                        "log_group_name": "/${loggroup_prefix}var/log/cloud-init.log",
                        "log_stream_name": "{instance_id}"
                    },
                    {
                        "file_path": "/var/log/sudo.log*",
                        "timezone": "Local",
                        "timestamp_format": "%b %-d %H:%M:%S",
                        "multi_line_start_pattern": "{timestamp_format}",
                        "log_group_name": "/${loggroup_prefix}var/log/sudo.log",
                        "log_stream_name": "{instance_id}"
                    },
                    {
                        "file_path": "/var/ossec/logs/ossec.log*",
                        "timezone": "Local",
                        "timestamp_format": "%Y/%m/%d %H:%M:%S",
                        "log_group_name": "/${loggroup_prefix}var/ossec/logs/ossec.log",
                        "log_stream_name": "{instance_id}"
                    },
                    {
                        "file_path": "/var/ossec/logs/alerts/alerts.json",
                        "timezone": "Local",
                        "timestamp_format": "%Y-%m-%dT%H:%M:%S.%f",
                        "log_group_name": "/${loggroup_prefix}var/ossec/logs/alerts/alerts.json",
                        "log_stream_name": "{instance_id}"
                    }
HERE

if [[ -n $files_collect_list ]]; then
    echo ",$files_collect_list" >> /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
fi

cat >> /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<HERE
                ]
            }
        }
    },
    "metrics": {
        "namespace": "${metrics_namespace}",
HERE

if [[ $metrics_autoscaling_group =~ ^yes|y|t|true|1$ ]]; then
    cat >> /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<HERE
        "append_dimensions": {
            "AutoScalingGroupName": "\${aws:AutoScalingGroupName}",
            "InstanceId": "\${aws:InstanceId}"
        },
        "aggregation_dimensions": [
            ["AutoScalingGroupName"]
        ],
HERE
else
    cat >> /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<HERE
        "append_dimensions": {
            "InstanceId": "\${aws:InstanceId}"
        },
HERE
fi

cat >> /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<HERE
        "metrics_collected": {
            "cpu": {
                "measurement": [
                    "cpu_usage_idle",
                    "cpu_usage_iowait",
                    "cpu_usage_user",
                    "cpu_usage_system"
                ],
                "resources": [ "*" ],
                "totalcpu": true
            },
            "disk": {
                "measurement": [
                    "used_percent",
                    "inodes_free"
                ],
                "resources": [ "*" ],
                "ignore_file_system_types": [
                    "sysfs",
                    "devtmpfs",
                    "tmpfs",
                    "nfs4"
                ],
                "metrics_collection_interval": 900
            },
            "mem": {
                "measurement": [
                    "mem_used_percent"
                ]
            },
            "swap": {
                "measurement": [
                    "swap_used_percent"
                ]
            }
        }
    }
}
HERE
chown root:root /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
chmod 0644 /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

illinois_log "translating CWAgent config file"
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s

if [[ -n $journald_cloudwatch_logs_package ]]; then
    if ! id journald-cloudwatch-logs &>/dev/null; then
        illinois_log "creating journald-cloudwatch-logs user"
        useradd --system --no-create-home --shell /bin/false --user-group --groups systemd-journal journald-cloudwatch-logs
    fi

    journald_cloudwatch_logs=/usr/local/bin/journald-cloudwatch-logs
    illinois_log "getting the journald-cloudwatch-logs from $journald_cloudwatch_logs_package"
    aws s3 cp $journald_cloudwatch_logs_package "$journald_cloudwatch_logs" --quiet
    chown root:root "$journald_cloudwatch_logs"
    chmod 0755 "$journald_cloudwatch_logs"

    [[ -e /etc/opt/illinois ]] || mkdir -p /etc/opt/illinois/
    [[ -e /var/lib/journald-cloudwatch-logs ]] || mkdir -p /var/lib/journald-cloudwatch-logs/
    chown -R journald-cloudwatch-logs: /var/lib/journald-cloudwatch-logs
    chmod 0700 /var/lib/journald-cloudwatch-logs

    illinois_log "creating journald-cloudwatch-logs.hcl file"
    illinois_write_file /etc/opt/illinois/journald-cloudwatch-logs.hcl <<EOF
log_group = "/${loggroup_prefix}journald"

// (you'll need to create this directory before starting the program)
state_file = "/var/lib/journald-cloudwatch-logs/state"
EOF

    illinois_log "creating journald-cloudwatch-logs.service file"
    [[ -e /usr/local/lib/systemd/system ]] || mkdir -p /usr/local/lib/systemd/system
    illinois_write_file /usr/local/lib/systemd/system/journald-cloudwatch-logs.service <<EOF
[Unit]
Description=Sends journald logs to CloudWatch Logs
After=network.target

[Service]
User=journald-cloudwatch-logs
Group=journald-cloudwatch-logs
ExecStart=/usr/local/bin/journald-cloudwatch-logs /etc/opt/illinois/journald-cloudwatch-logs.hcl
KillMode=process
Restart=on-failure
RestartSec=60s

[Install]
WantedBy=multi-user.target
EOF

    illinois_log "starting journald-cloudwatch-logs"
    systemctl daemon-reload
    systemctl enable --now journald-cloudwatch-logs
fi

illinois_init_status finished
date > /var/lib/illinois-ec2logs-init
