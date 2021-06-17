file=/etc/opt/illinois/cloud-init/asg.conf
mkdir -p "$(dirname "$file")"
cat << "EOF" > "$file"
asg_name=${asg_name}
EOF
chmod 0644 "$file"
chown root:root "$file"

file=/etc/opt/illinois/cloud-init/efs/sharedfs
mkdir -p "$(dirname "$file")"
cat << "EOF" > "$file"
efs_filesystem_id=${sharedfs_id}
EOF
chmod 0644 "$file"
chown root:root "$file"

file=/etc/opt/illinois/cloud-init/efs/home_uofi
mkdir -p "$(dirname "$file")"
cat << "EOF" > "$file"
efs_filesystem_id=${sharedfs_id}
efs_options=tls,noresvport,accesspoint=${sharedfs_home_uofi_id}
mount_target=/home/ad.uillinois.edu
EOF
chmod 0644 "$file"
chown root:root "$file"

file=/etc/opt/illinois/cloud-init/ec2logs.conf
mkdir -p "$(dirname "$file")"
cat << "EOF" > "$file"
loggroup_prefix="${loggroup_prefix}"
metrics_collection_interval=${metrics_collection_interval}
metrics_namespace=${metrics_namespace}
EOF
chmod 0644 "$file"
chown root:root "$file"

file=/etc/opt/illinois/cloud-init/ssh.conf
mkdir -p "$(dirname "$file")"
cat << "EOF" > "$file"
ssh_hostkeys_path="${ssh_hostkeys_path}"
EOF
chmod 0644 "$file"
chown root:root "$file"

file=/etc/opt/illinois/cloud-init/sss.conf
mkdir -p "$(dirname "$file")"
cat << "EOF" > "$file"
sss_admingroups_parameter="${sss_admingroups_parameter}"
sss_allowgroups_parameter="${sss_allowgroups_parameter}"
sss_binduser_parameter="${sss_binduser_parameter}"
sss_bindpass_parameter="${sss_bindpass_parameter}"
EOF
chmod 0644 "$file"
chown root:root "$file"

file=/etc/opt/illinois/cloud-init/extra-enis.conf
mkdir -p "$(dirname "$file")"
cat << "EOF" > "$file"
declare -A extra_enis_prefix_list_ids=( ${extra_enis_prefix_list_ids} )
EOF
chmod 0644 "$file"
chown root:root "$file"

file=/etc/opt/illinois/cloud-init/falcon-sensor.conf
mkdir -p "$(dirname "$file")"
cat << "EOF" > "$file"
falcon_sensor_package="${falcon_sensor_package}"
falcon_sensor_cid_path="${falcon_sensor_cid_path}"
EOF
chmod 0644 "$file"
chown root:root "$file"


if ! egrep -q '^\s*root:' /etc/aliases; then
    echo "root: ${contact}" >> /etc/aliases
    newaliases
fi

file=/etc/profile.d/illinois-prompt.sh
mkdir -p "$(dirname "$file")"
cat << "EOF" > "$file"
[ "$PS1" ] && PS1="[\u@${prompt_name} \W]\\$ "
EOF
chmod 0644 "$file"
chown root:root "$file"
