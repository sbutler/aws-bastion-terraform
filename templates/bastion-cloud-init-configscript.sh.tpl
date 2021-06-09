file=/etc/opt/illinois/cloud-init/efs/homefs
mkdir -p "$(dirname "$file")"
cat << EOF > "$file"
efs_filesystem_id=${homefs_id}
mount_target=/home/ad.uillinois.edu
EOF
chmod 0644 "$file"
chown root:root "$file"

file=/etc/opt/illinois/cloud-init/ec2logs.conf
mkdir -p "$(dirname "$file")"
cat << EOF > "$file"
loggroup_prefix="${loggroup_prefix}"
metrics_collection_interval=${metrics_collection_interval}
metrics_namespace=${metrics_namespace}
EOF
chmod 0644 "$file"
chown root:root "$file"

file=/etc/opt/illinois/cloud-init/ssh.conf
mkdir -p "$(dirname "$file")"
cat << EOF > "$file"
ssh_hostkeys_path="${ssh_hostkeys_path}"
EOF
chmod 0644 "$file"
chown root:root "$file"

file=/etc/opt/illinois/cloud-init/sss.conf
mkdir -p "$(dirname "$file")"
cat << EOF > "$file"
sss_admin_groups="${sss_admin_groups}"
sss_allow_groups="${sss_allow_groups}"
sss_binduser_parameter="${sss_binduser_parameter}"
sss_bindpass_parameter="${sss_bindpass_parameter}"
EOF
chmod 0644 "$file"
chown root:root "$file"

if ! egrep -q '^\s*root:' /etc/aliases; then
    echo "root: ${contact}" >> /etc/aliases
    newaliases
fi
