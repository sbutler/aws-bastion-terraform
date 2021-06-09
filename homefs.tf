# =========================================================
# Data
# =========================================================

data "aws_kms_alias" "efs" {
    name = "alias/aws/elasticfilesystem"
}

# =========================================================
# Resources
# =========================================================

resource "aws_security_group" "homefs" {
    name_prefix = "${local.name_prefix}bastion-homefs-"
    description = "Home filesystem for bastion hosts."
    vpc_id      = local.internal_vpc_id

    ingress {
        protocol  = "tcp"
        from_port = 2049
        to_port   = 2049
        security_groups = [
            aws_security_group.bastion.id,
        ]
    }

    egress {
        from_port   = 0
        to_port     = 0
        protocol    = "-1"
        cidr_blocks = [ "0.0.0.0/0" ]
    }

    tags = {
        Name = "${var.service} Home Filesystem"
    }
}

resource "aws_efs_file_system" "homefs" {
    encrypted  = true
    kms_key_id = data.aws_kms_alias.efs.target_key_arn

    tags = {
        Name               = "${local.name_prefix}bastion-homefs"
        DataClassification = "Internal"
    }

    lifecycle {
        prevent_destroy = false
    }
}

# Create one sharedfs mount target per subnet.
resource "aws_efs_mount_target" "homefs" {
    count = length(local.internal_subnet_ids)

    file_system_id  = aws_efs_file_system.homefs.id
    subnet_id       = local.internal_subnet_ids[count.index]
    security_groups = [ aws_security_group.homefs.id ]
}
