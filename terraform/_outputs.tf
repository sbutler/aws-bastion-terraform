# =========================================================
# AutoScaling Group
# =========================================================

output "bastion_autoscaling_group" {
    value = {
        arn  = aws_autoscaling_group.bastion.arn
        name = aws_autoscaling_group.bastion.name
    }
}

resource "aws_ssm_parameter" "bastion_autoscaling_group_outputs" {
    for_each = {
        arn  = aws_autoscaling_group.bastion.arn
        name = aws_autoscaling_group.bastion.name
    }

    name        = "/${local.outputs_parameter_prefix}autoscaling-group/${each.key}"
    description = "${var.service} bastion host AutoScaling Group ${each.key}."

    type      = "String"
    value     = each.value
    overwrite = true
}

# =========================================================
# IAM Instance Profile
# =========================================================

output "bastion_instance_profile" {
    value = {
        arn       = aws_iam_instance_profile.bastion.arn
        name      = aws_iam_instance_profile.bastion.name
        unique_id = aws_iam_instance_profile.bastion.unique_id
    }
}

resource "aws_ssm_parameter" "bastion_instance_profile_outputs" {
    for_each = {
        arn       = aws_iam_instance_profile.bastion.arn
        name      = aws_iam_instance_profile.bastion.name
        unique-id = aws_iam_instance_profile.bastion.unique_id
    }

    name        = "/${local.outputs_parameter_prefix}instance-profile/${each.key}"
    description = "${var.service} bastion host IAM Instance Profile ${each.key}."

    type      = "String"
    value     = each.value
    overwrite = true
}

# =========================================================
# EIP
# =========================================================

output "bastion_public_ip" {
    value = aws_eip.bastion.public_ip
}

resource "aws_ssm_parameter" "bastion_public_ip_output" {
    name        = "/${local.outputs_parameter_prefix}public-ip"
    description = "${var.service} bastion host public IP."

    type      = "String"
    value     = aws_eip.bastion.public_ip
    overwrite = true
}

# =========================================================
# IAM Role
# =========================================================

output "bastion_role" {
    value = {
        arn       = aws_iam_role.bastion.arn
        name      = aws_iam_role.bastion.name
        unique_id = aws_iam_role.bastion.unique_id
    }
}

resource "aws_ssm_parameter" "bastion_role_outputs" {
    for_each = {
        arn       = aws_iam_role.bastion.arn
        name      = aws_iam_role.bastion.name
        unique-id = aws_iam_role.bastion.unique_id
    }

    name        = "/${local.outputs_parameter_prefix}role/${each.key}"
    description = "${var.service} bastion host IAM Role ${each.key}."

    type      = "String"
    value     = each.value
    overwrite = true
}

# =========================================================
# Security Group
# =========================================================

output "bastion_security_group" {
    value = {
        arn  = aws_security_group.bastion.arn
        id   = aws_security_group.bastion.id
        name = aws_security_group.bastion.name
    }
}

resource "aws_ssm_parameter" "bastion_security_group_outputs" {
    for_each = {
        arn  = aws_security_group.bastion.arn
        id   = aws_security_group.bastion.id
        name = aws_security_group.bastion.name
    }

    name        = "/${local.outputs_parameter_prefix}security-group/${each.key}"
    description = "${var.service} bastion host VPC Security Group ${each.key}."

    type      = "String"
    value     = each.value
    overwrite = true
}

# =========================================================
# SharedFS
# =========================================================

output "bastion_sharedfs" {
    value = {
        arn = aws_efs_file_system.sharedfs.arn
        id  = aws_efs_file_system.sharedfs.id
    }
}

resource "aws_ssm_parameter" "bastion_sharedfs_outputs" {
    for_each = {
        arn = aws_efs_file_system.sharedfs.arn
        id  = aws_efs_file_system.sharedfs.id
    }

    name        = "/${local.outputs_parameter_prefix}sharedfs/${each.key}"
    description = "${var.service} bastion host SharedFS ${each.key}."

    type      = "String"
    value     = each.value
    overwrite = true
}
