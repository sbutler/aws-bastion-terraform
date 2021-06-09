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
    part {
        filename     = "init.sh"
        content_type = "text/cloud-boothook"
        content      = templatefile(
            "templates/bastion-cloud-init-configscript.sh.tpl",
            {
                region   = data.aws_region.current.name
                contact  = var.contact
                asg_name = local.asg_name

                homefs_id = aws_efs_file_system.homefs.id

                loggroup_prefix             = local.loggroup_prefix
                metrics_namespace           = local.metrics_namespace
                metrics_collection_interval = var.enhanced_monitoring ? 60 : 300

                sss_admin_groups = join(", ",
                    [ for g in var.admin_groups : "%${replace(g, " ", "\\ ")}" ]
                )
                sss_allow_groups = join(", ",
                    distinct(concat(
                        var.admin_groups,
                        var.allow_groups,
                    ))
                )
                sss_binduser_parameter = "/${local.sss_parameter_prefix}bind-username"
                sss_bindpass_parameter = "/${local.sss_parameter_prefix}bind-password"

                ssh_hostkeys_path = "/${local.ssh_parameter_prefix}"
            }
        )
    }

    part {
        filename     = "includes1.txt"
        content_type = "text/x-include-url"
        content = <<EOF
https://static.ics.illinois.edu/cloud-init/20210608/efs.sh
https://static.ics.illinois.edu/cloud-init/20210608/awscli.sh
https://static.ics.illinois.edu/cloud-init/20210608/ec2logs.yml
https://static.ics.illinois.edu/cloud-init/20210608/yumcron.yml
https://static.ics.illinois.edu/cloud-init/20210608/ssh.sh
https://static.ics.illinois.edu/cloud-init/20210608/sss.sh
EOF
    }
    part {
        filename     = "config-bastion.yml"
        content_type = "text/cloud-config"
        content      = file("files/cloud-init/config-bastion.yml")
    }

    part {
        filename     = "config-prompt.yml"
        content_type = "text/cloud-config"
        content      = templatefile(
            "templates/cloud-init/config-prompt.yml.tpl",
            {
                prompt_name = "${local.name_prefix}bastion"
            }
        )
    }
}

# =========================================================
# Locals
# =========================================================

locals {
    asg_name = "${local.name_prefix}bastion"
}

# =========================================================
# Resources
# =========================================================

resource "aws_security_group" "bastion" {
    name_prefix = "${local.name_prefix}bastion-"
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
        Name = "${local.name_prefix}bastion"
    }
}

resource "aws_launch_template" "bastion" {
    name_prefix = "${local.name_prefix}bastion-"
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
        }
    }

    tag_specifications {
        resource_type = "instance"
        tags = merge(
            local.default_tags,
            { Name = "${local.name_prefix}bastion" },
        )
    }

    tag_specifications {
        resource_type = "volume"
        tags = merge(
            local.default_tags,
            { Name = "${local.name_prefix}bastion-root" },
        )
    }

    tags = {
        Name = "${local.name_prefix}bastion"
    }

    lifecycle {
        ignore_changes = [ image_id ]
        create_before_destroy = true
    }
}

resource "aws_autoscaling_group" "bastion" {
    depends_on = [
        time_sleep.bastion_role,
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
