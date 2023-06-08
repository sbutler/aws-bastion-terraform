# =========================================================
# Data
# =========================================================

data "aws_ssm_document" "run_patch_baseline" {
    name            = "AWS-RunPatchBaseline"
    document_format = "YAML"
}

data "aws_ssm_patch_baseline" "amazon_linux2" {
    owner            = "AWS"
    name_prefix      = "AWS-AmazonLinux2DefaultPatchBaseline"
    operating_system = "AMAZON_LINUX_2"
}

data "aws_iam_policy_document" "ssm_patching" {
    statement {
        effect = "Allow"

        actions = [
            "ssm:SendCommand",
            "ssm:CancelCommand",
            "ssm:ListCommands",
            "ssm:ListCommandInvocations",
            "ssm:GetCommandInvocation",
            "ssm:ListTagsForResource",
            "ssm:GetParameters",
        ]
        resources = [ "*" ]
    }

    statement {
        effect = "Allow"

        actions = [
            "resource-groups:ListGroups",
            "resource-groups:ListGroupResources",
        ]
        resources = [ "*" ]
    }

    statement {
        effect = "Allow"

        actions = [
            "tag:GetResources"
        ]
        resources = [ "*" ]
    }

    statement {
        effect = "Allow"

        actions = [ "iam:PassRole" ]
        resources = [ "*" ]

        condition {
            test = "StringEquals"
            variable = "iam:PassedToService"

            values = [ "ssm.amazonaws.com" ]
        }
    }
}

# =========================================================
# Resources: IAM
# =========================================================

resource "aws_iam_role" "ssm_patching" {
    name_prefix = "${substr(local.name_prefix, 0, 24)}ssm-"
    path        = "/${var.project}/"
    description = "Bastion SSM Patching Tasks."

    assume_role_policy = data.aws_iam_policy_document.ssm_assume_role.json
}

resource "aws_iam_role_policy" "ssm_patching" {
    name   = "ssm"

    role   = aws_iam_role.ssm_patching.name
    policy = data.aws_iam_policy_document.ssm_patching.json

    lifecycle {
        create_before_destroy = true
    }
}

resource "time_sleep" "waiton_ssm_patching_role" {
    create_duration = "10s"

    triggers = {
        role = aws_iam_role.ssm_patching.name

        policy = aws_iam_role_policy.ssm_patching.id
    }
}

# =========================================================
# Resources: SSM
# =========================================================

resource "aws_ssm_patch_group" "bastion" {
    baseline_id = data.aws_ssm_patch_baseline.amazon_linux2.id
    patch_group = local.asg_name
}

# =========================================================
# Resources: SSM Scanning
# =========================================================

resource "aws_ssm_maintenance_window" "bastion_scanning" {
    name              = local.asg_name
    description       = "Daily baseline scanning of Bastion servers."
    schedule          = var.ssm_maintenance_window_scanning
    schedule_timezone = "America/Chicago"

    duration = 1
    cutoff   = 1

    allow_unassociated_targets = false
}

resource "aws_ssm_maintenance_window_target" "bastion_scanning_asg" {
    window_id     = aws_ssm_maintenance_window.bastion_scanning.id
    name          = "ASG-${local.asg_name}"
    description   = "Maintenance window for Bastion servers in the ASG."

    resource_type = "INSTANCE"

    targets {
        key    = "tag:aws:autoscaling:groupName"
        values = [ local.asg_name ]
    }
}

resource "aws_ssm_maintenance_window_task" "bastion_scanning" {
   depends_on = [
        time_sleep.waiton_ssm_patching_role,
    ]

    window_id = aws_ssm_maintenance_window.bastion_scanning.id

    priority        = 1
    max_concurrency = 2
    max_errors      = 1

    task_arn  = data.aws_ssm_document.run_patch_baseline.arn
    task_type = "RUN_COMMAND"

    targets {
        key    = "WindowTargetIds"
        values = [ aws_ssm_maintenance_window_target.bastion_scanning_asg.id ]
    }

    task_invocation_parameters {
        run_command_parameters {
            service_role_arn = aws_iam_role.ssm_patching.arn
            timeout_seconds  = 900

            parameter {
                name   = "Operation"
                values = [ "Scan" ]
            }

            parameter {
                name   = "RebootOption"
                values = [ "NoReboot" ]
            }
        }
    }
}

# =========================================================
# Resources: SSM Patching
# =========================================================

resource "aws_ssm_maintenance_window" "bastion_patching" {
    name              = local.asg_name
    description       = "Weekly baseline patching of Bastion servers."
    schedule          = var.ssm_maintenance_window_patching
    schedule_timezone = "America/Chicago"

    duration = 3
    cutoff   = 1

    allow_unassociated_targets = false
}

resource "aws_ssm_maintenance_window_target" "bastion_patching_asg" {
    window_id     = aws_ssm_maintenance_window.bastion_patching.id
    name          = "ASG-${local.asg_name}"
    description   = "Maintenance window for Bastion servers in the ASG."

    resource_type = "INSTANCE"

    targets {
        key    = "tag:aws:autoscaling:groupName"
        values = [ local.asg_name ]
    }
}

resource "aws_ssm_maintenance_window_task" "bastion_patching" {
   depends_on = [
        time_sleep.waiton_ssm_patching_role,
    ]

    window_id = aws_ssm_maintenance_window.bastion_patching.id

    priority        = 1
    max_concurrency = 2
    max_errors      = 1

    task_arn  = data.aws_ssm_document.run_patch_baseline.arn
    task_type = "RUN_COMMAND"

    targets {
        key    = "WindowTargetIds"
        values = [ aws_ssm_maintenance_window_target.bastion_patching_asg.id ]
    }

    task_invocation_parameters {
        run_command_parameters {
            service_role_arn = aws_iam_role.ssm_patching.arn
            timeout_seconds  = 900

            parameter {
                name   = "Operation"
                values = [ "Install" ]
            }

            parameter {
                name   = "RebootOption"
                values = [ "RebootIfNeeded" ]
            }
        }
    }
}
