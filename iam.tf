# =========================================================
# Data
# =========================================================

data "aws_iam_policy_document" "bastion_ssm_parameters" {
    statement {
        sid    = "Global"
        effect = "Allow"

        actions = [
            "ssm:DescribeParameters"
        ]

        resources = [ "*" ]
    }

    statement {
        sid    = "Limited"
        effect = "Allow"

        actions = [ "ssm:GetParameter*" ]

        resources = [
            "arn:aws:ssm:${local.region_name}:${local.account_id}:parameter/${local.ssh_parameter_prefix}*",
            "arn:aws:ssm:${local.region_name}:${local.account_id}:parameter/${local.sss_parameter_prefix}*",
        ]
    }
}

data "aws_iam_policy_document" "bastion_logs" {
    statement {
        sid    = "Global"
        effect = "Allow"

        actions = [

            "ec2:DescribeTags",
        ]

        resources = [ "*" ]
    }

    statement {
        sid    = "MetricsLimited"
        effect = "Allow"

        actions = [
            "cloudwatch:PutMetricData",
        ]

        resources = [ "*" ]

        condition {
            test     = "StringEquals"
            variable = "cloudwatch:namespace"

            values = [ local.metrics_namespace ]
        }
    }

    statement {
        sid    = "LogsLimitedRead"
        effect = "Allow"

        actions = [
            "logs:DescribeLogGroups",
            "logs:DescribeLogStreams",
        ]

        resources = [ "arn:aws:logs:${local.region_name}:${local.account_id}:*" ]
    }

    statement {
        sid    = "LogsLimitedWrite"
        effect = "Allow"

        actions = [
            "logs:CreateLogGroup",
            "logs:CreateLogStream",
            "logs:PutLogEvents",
        ]

        resources = [
            "arn:aws:logs:${local.region_name}:${local.account_id}:log-group:/${local.loggroup_prefix}*",
            "arn:aws:logs:${local.region_name}:${local.account_id}:log-group:/${local.loggroup_prefix}*:*",
        ]
    }
}

# =========================================================
# Resources
# =========================================================

resource "aws_iam_instance_profile" "bastion" {
    name_prefix = "${local.name_prefix}bastion-"
    role        = aws_iam_role.bastion.name
}

resource "aws_iam_role" "bastion" {
    name_prefix = "${local.name_prefix}bastion-"
    description = "EC2 ${local.name_prefix}bastion instance role"

    assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_role_policy" "bastion_ssm_parameters" {
    name   = "ssm-parameters"
    role   = aws_iam_role.bastion.id
    policy = data.aws_iam_policy_document.bastion_ssm_parameters.json
}

resource "aws_iam_role_policy" "bastion_logs" {
    name   = "logs"
    role   = aws_iam_role.bastion.id
    policy = data.aws_iam_policy_document.bastion_logs.json
}

resource "aws_iam_role_policy_attachment" "bastion_ssm" {
    role       = aws_iam_role.bastion.name
    policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"

    lifecycle {
        create_before_destroy = true
    }
}

resource "time_sleep" "bastion_role" {
    triggers = {
        ssm            = aws_iam_role_policy_attachment.bastion_ssm.id
        ssm_parameters = aws_iam_role_policy.bastion_ssm_parameters.id
        logs           = aws_iam_role_policy.bastion_logs.id
    }

    create_duration = "10s"
}