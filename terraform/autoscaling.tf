# =========================================================
# Data
# =========================================================

data "aws_ami" "amazon_linux2" {
    most_recent = true
    filter {
        name   = "name"
        values = [ "amzn2-ami-hvm-*-gp2" ]
    }
    filter {
        name   = "virtualization-type"
        values = [ "hvm" ]
    }
    filter {
        name   = "architecture"
        values = [ "x86_64" ]
    }
    owners = [ "amazon" ]
}

# =========================================================
# Data: Cloud Init
# =========================================================

data "cloudinit_config" "bastion_userdata" {
    depends_on = [
        aws_s3_bucket_object.assets_cloudinit_ec2logsyml,
        aws_s3_bucket_object.assets_cloudinit_efssh,
        aws_s3_bucket_object.assets_cloudinit_extraenissh,
        aws_s3_bucket_object.assets_cloudinit_falconsensorsh,
        aws_s3_bucket_object.assets_cloudinit_initsh,
        aws_s3_bucket_object.assets_cloudinit_ossecsh,
        aws_s3_bucket_object.assets_cloudinit_s3downloadsh,
        aws_s3_bucket_object.assets_cloudinit_sshsh,
        aws_s3_bucket_object.assets_cloudinit_ssssh,
        aws_s3_bucket_object.assets_cloudinit_yumcronyml,
    ]

    part {
        filename     = "init.sh"
        content_type = "text/cloud-boothook"
        content      = templatefile(
            "templates/bastion-cloud-init-configscript.sh",
            {
                region      = data.aws_region.current.name
                contact     = var.contact
                asg_name    = local.asg_name
                prompt_name = local.name

                sharedfs_id           = aws_efs_file_system.sharedfs.id
                sharedfs_home_uofi_id = aws_efs_access_point.sharedfs_home_uofi.id

                loggroup_prefix             = local.loggroup_prefix
                metrics_namespace           = local.metrics_namespace
                metrics_collection_interval = var.enhanced_monitoring ? 60 : 300

                sss_admingroups_parameter = "/${local.sss_parameter_prefix}admin-groups"
                sss_allowgroups_parameter = "/${local.sss_parameter_prefix}allow-groups"
                sss_binduser_parameter    = "/${local.sss_parameter_prefix}bind-username"
                sss_bindpass_parameter    = "/${local.sss_parameter_prefix}bind-password"

                ssh_hostkeys_path = "/${local.ssh_parameter_prefix}"

                extra_enis_prefix_list_ids = join(" ", formatlist(
                    "[eth%d]='%s'",
                    [ for i in range(length(local.extra_enis)) : i + 1 ],
                    [ for o in local.extra_enis : join(" ", o.prefix_list_ids) ]
                ))

                falcon_sensor_package  = coalesce(var.falcon_sensor_package, "")
                falcon_sensor_cid_path = "/${local.falcon_sensor_parameter_prefix}CID"

                ossec_whitelists_path = "/${local.ossec_parameter_prefix}whitelists"
            }
        )
    }

    part {
        filename     = "includes1.txt"
        content_type = "text/x-include-url"
        content = <<EOF
https://${aws_s3_bucket.assets.bucket_regional_domain_name}/cloud-init/init.sh
https://${aws_s3_bucket.assets.bucket_regional_domain_name}/cloud-init/efs.sh
https://${aws_s3_bucket.assets.bucket_regional_domain_name}/cloud-init/extra-enis.sh
https://${aws_s3_bucket.assets.bucket_regional_domain_name}/cloud-init/ec2logs.yml
https://${aws_s3_bucket.assets.bucket_regional_domain_name}/cloud-init/yumcron.yml
https://${aws_s3_bucket.assets.bucket_regional_domain_name}/cloud-init/ssh.sh
https://${aws_s3_bucket.assets.bucket_regional_domain_name}/cloud-init/sss.sh
https://${aws_s3_bucket.assets.bucket_regional_domain_name}/cloud-init/falcon-sensor.sh
https://${aws_s3_bucket.assets.bucket_regional_domain_name}/cloud-init/ossec.sh
EOF
    }

    part {
        filename     = "config-bastion.yml"
        content_type = "text/cloud-config"
        content      = templatefile("templates/config-bastion.yml", {
            hostname = var.hostname
        })
    }
}

# =========================================================
# Locals
# =========================================================

locals {
    asg_name            = local.name
    instance_name       = local.name
    security_group_name = local.name
}

# =========================================================
# Resources
# =========================================================

resource "aws_security_group" "bastion" {
    name_prefix = local.name_prefix
    description = "Bastion host group."
    vpc_id      = local.vpc_id

    ingress {
        description = "SSH"

        protocol  = "tcp"
        from_port = 22
        to_port   = 22

        cidr_blocks      = [ "0.0.0.0/0" ]
        ipv6_cidr_blocks = [ "::/0" ]
    }

    egress {
        from_port = 0
        to_port   = 0
        protocol  = "-1"

        cidr_blocks      = [ "0.0.0.0/0" ]
        ipv6_cidr_blocks = [ "::/0" ]
    }

    tags = {
        Name = local.security_group_name
    }
}

resource "aws_launch_template" "bastion" {
    name_prefix = local.name_prefix
    description = "Bastion host configuration"

    image_id      = data.aws_ami.amazon_linux2.id
    instance_type = var.instance_type
    iam_instance_profile {
        name = aws_iam_instance_profile.bastion.name
    }
    credit_specification {
        cpu_credits = substr(var.instance_type, 0, 2) == "t3" || substr(var.instance_type, 0, 2) == "t2" ? "unlimited" : "standard"
    }
    monitoring {
        enabled = var.enhanced_monitoring
    }

    key_name               = var.key_name
    vpc_security_group_ids = [ aws_security_group.bastion.id ]
    user_data              = data.cloudinit_config.bastion_userdata.rendered

    block_device_mappings {
        device_name = "/dev/xvda"

        ebs {
            delete_on_termination = true
            volume_size           = 30
            volume_type           = "gp3"

            encrypted  = true
            kms_key_id = aws_kms_key.data.arn
        }
    }

    tag_specifications {
        resource_type = "instance"
        tags = merge(
            local.default_tags,
            { Name = local.instance_name },
        )
    }

    tag_specifications {
        resource_type = "volume"
        tags = merge(
            local.default_tags,
            { Name = "${local.name_prefix}root" },
        )
    }

    tags = {
        Name = local.name
    }

    lifecycle {
        ignore_changes = [ image_id ]
        create_before_destroy = true
    }
}

resource "aws_autoscaling_group" "bastion" {
    depends_on = [
        time_sleep.bastion_role,
        aws_efs_mount_target.sharedfs,
    ]

    name             = local.asg_name
    min_size         = 1
    max_size         = 2
    desired_capacity = 1

    default_cooldown          = 300
    health_check_grace_period = 600
    health_check_type         = "EC2"
    termination_policies = [
        "OldestInstance",
        "OldestLaunchTemplate",
    ]

    vpc_zone_identifier = local.public_subnet_ids

    launch_template {
        id      = aws_launch_template.bastion.id
        version = aws_launch_template.bastion.latest_version
    }
}