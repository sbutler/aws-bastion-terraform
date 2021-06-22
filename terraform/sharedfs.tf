# =========================================================
# Resources
# =========================================================

resource "aws_security_group" "sharedfs" {
    name_prefix = "${local.name_prefix}bastion-sharedfs-"
    description = "Shared filesystem for bastion hosts."
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
        Name = "${var.service} Shared Filesystem"
    }
}

resource "aws_efs_file_system" "sharedfs" {
    encrypted  = true
    kms_key_id = aws_kms_key.data.arn

    tags = {
        Name               = "${local.name_prefix}bastion-sharedfs"
        DataClassification = "Internal"
    }

    lifecycle {
        #prevent_destroy = true
    }
}

resource "aws_efs_access_point" "sharedfs_home_uofi" {
    file_system_id = aws_efs_file_system.sharedfs.id
    root_directory {
        path = "/home/ad.uillinois.edu"
        creation_info {
            owner_uid   = 0
            owner_gid   = 0
            permissions = "755"
        }
    }
}

# Create one sharedfs mount target per subnet.
resource "aws_efs_mount_target" "sharedfs" {
    count = length(local.internal_subnet_ids)

    file_system_id  = aws_efs_file_system.sharedfs.id
    subnet_id       = local.internal_subnet_ids[count.index]
    security_groups = [ aws_security_group.sharedfs.id ]
}
