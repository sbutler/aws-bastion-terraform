#cloud-boothook
#!/bin/bash

write_file () {
    local file="$1"
    local filepath="$(dirname "$file")"
    local mode="$${2:-0644}"
    local owner="$${3:-root:root}"

    [[ -e $filepath ]] || mkdir -p "$filepath"
    cat > "$file"
    chmod $mode "$file"
    chown "$owner" "$file"
}

write_file /etc/opt/illinois/cloud-init/asg.conf << "EOF"
asg_name=${asg_name}
EOF

write_file /etc/opt/illinois/cloud-init/efs/bastion-sharedfs << "EOF"
efs_filesystem_id=${sharedfs_id}
declare -A efs_mount_targets=( ${sharedfs_mount_targets} )
EOF

write_file /etc/opt/illinois/cloud-init/efs/bastion-home-uofi << "EOF"
efs_filesystem_id=${sharedfs_id}
efs_options=tls,noresvport,accesspoint=${sharedfs_home_uofi_id}
mount_target=/home/ad.uillinois.edu
declare -A efs_mount_targets=( ${sharedfs_mount_targets} )
EOF

write_file /etc/opt/illinois/cloud-init/efs/bastion-var-spool-at << "EOF"
efs_filesystem_id=${sharedfs_id}
efs_options=tls,noresvport,accesspoint=${sharedfs_var_spool_at_id}
mount_target=/var/spool/at
declare -A efs_mount_targets=( ${sharedfs_mount_targets} )
EOF

write_file /etc/opt/illinois/cloud-init/efs/bastion-var-spool-cron << "EOF"
efs_filesystem_id=${sharedfs_id}
efs_options=tls,noresvport,accesspoint=${sharedfs_var_spool_cron_id}
mount_target=/var/spool/cron
declare -A efs_mount_targets=( ${sharedfs_mount_targets} )
EOF

%{for efs_name, efs_config in extra_efs }
write_file /etc/opt/illinois/cloud-init/efs/${efs_name} << "EOF"
efs_filesystem_id=${efs_config.filesystem_id}
mount_target=${efs_config.mount_target}
efs_options=${efs_config.options}
EOF
%{ endfor ~}

write_file /etc/opt/illinois/cloud-init/ec2logs.conf << "EOF"
loggroup_prefix="${loggroup_prefix}"
metrics_collection_interval=${metrics_collection_interval}
metrics_namespace=${metrics_namespace}
journald_cloudwatch_logs_package="${journald_cloudwatch_logs_package}"
EOF

write_file /etc/opt/illinois/cloud-init/cis.conf << "EOF"
cis_shell_timeout=${cis_shell_timeout}
EOF

write_file /etc/opt/illinois/cloud-init/ssh.conf << "EOF"
ssh_hostkeys_path="${ssh_hostkeys_path}"
ssh_client_alive_interval=${ssh_client_alive_interval}
ssh_client_alive_count_max=${ssh_client_alive_count_max}
EOF

write_file /etc/opt/illinois/cloud-init/sss.conf << "EOF"
sss_admingroups_parameter="${sss_admingroups_parameter}"
sss_allowgroups_parameter="${sss_allowgroups_parameter}"
sss_binduser_parameter="${sss_binduser_parameter}"
sss_bindpass_parameter="${sss_bindpass_parameter}"
EOF

write_file /etc/opt/illinois/cloud-init/duo.conf << "EOF"
duo_ikey_parameter="${duo_ikey_parameter}"
duo_skey_parameter="${duo_skey_parameter}"
duo_host_parameter="${duo_host_parameter}"
EOF

write_file /etc/opt/illinois/cloud-init/cron.conf << "EOF"
cron_allow_parameter="${cron_allow_parameter}"
EOF

write_file /etc/opt/illinois/cloud-init/network.conf << "EOF"
internal_subnets=( ${internal_subnets} )
EOF

write_file /etc/opt/illinois/cloud-init/extra-enis.conf << "EOF"
declare -A extra_enis_table_id=( ${extra_enis_table_id} )
declare -A extra_enis_prefix_list_ids=( ${extra_enis_prefix_list_ids} )
EOF

write_file /etc/opt/illinois/cloud-init/falcon-sensor.conf << "EOF"
falcon_sensor_package="${falcon_sensor_package}"
falcon_sensor_cid_path="${falcon_sensor_cid_path}"
EOF

write_file /etc/opt/illinois/cloud-init/ossec.conf << "EOF"
ossec_whitelists_path="${ossec_whitelists_path}"
EOF

write_file /etc/issue << "EOF"
${login_banner}
EOF
write_file /etc/issue.net << "EOF"
${login_banner}
EOF


if ! egrep -q '^\s*root:' /etc/aliases; then
    echo "root: ${contact}" >> /etc/aliases
    newaliases
fi

write_file /etc/profile.d/illinois-prompt.sh << "EOF"
[ "$PS1" ] && PS1="[\u@${prompt_name} \W]\\$ "
EOF
