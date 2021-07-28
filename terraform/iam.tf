# =========================================================
# Data
# =========================================================

data "aws_iam_policy_document" "bastion_events" {
    statement {
        sid    = "Limited"
        effect = "Allow"

        actions = [
            "events:PutEvents",
        ]

        resources = [ "arn:aws:events:${local.region_name}:${local.account_id}:event-bus/default" ]

        condition {
            test     = "StringEquals"
            variable = "events:source"

            values = [ "bastion.aws.illinois.edu" ]
        }
    }
}

data "aws_iam_policy_document" "bastion_extra_enis" {
    count = local.has_extra_enis ? 1 : 0

    dynamic "statement" {
        for_each = length(local.extra_enis_prefix_list_arns) > 0 ? [ local.extra_enis_prefix_list_arns ] : []

        content {
            sid    = "PrefixLists"
            effect = "Allow"

            actions = [ "ec2:GetManagedPrefixListEntries" ]

            resources = statement.value
        }
    }

    /*
    dynamic "statement" {
        for_each = length(local.extra_enis_vpc_ids) > 0 ? [ local.extra_enis_vpc_ids ] : []

        content {
            sid    = "VPCs"
            effect = "Allow"

            actions = [ "ec2:DescribeVpcs" ]

            resources = [ "*" ]
        }
    }
    */
}

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
            "arn:aws:ssm:${local.region_name}:${local.account_id}:parameter/${local.falcon_sensor_parameter_prefix}*",
            "arn:aws:ssm:${local.region_name}:${local.account_id}:parameter/${local.ossec_parameter_prefix}*",
            "arn:aws:ssm:${local.region_name}:${local.account_id}:parameter/${local.duo_parameter_prefix}*",
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

data "aws_iam_policy_document" "bastion_falcon_sensor" {
    count = local.has_falcon_sensor ? 1 : 0

    statement {
        sid    = "Download"
        effect = "Allow"

        actions = [
            "s3:GetBucketLocation",
            "s3:GetObject*",
        ]

        resources = [
            "arn:aws:s3:::${local.falcon_sensor_package_bucket}",
            "arn:aws:s3:::${local.falcon_sensor_package_bucket}/${local.falcon_sensor_package_key}",
        ]
    }
}

# =========================================================
# Resources
# =========================================================

resource "aws_iam_instance_profile" "bastion" {
    name_prefix = local.name_prefix
    role        = aws_iam_role.bastion.name
}

resource "aws_iam_role" "bastion" {
    name_prefix = local.name_prefix
    description = "EC2 ${local.name} instance role"

    assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_role_policy" "bastion_events" {
    name   = "events"
    role   = aws_iam_role.bastion.id
    policy = data.aws_iam_policy_document.bastion_events.json
}

resource "aws_iam_role_policy" "bastion_extra_enis" {
    count = local.has_extra_enis ? 1 : 0

    name   = "extra-enis"
    role   = aws_iam_role.bastion.id
    policy = data.aws_iam_policy_document.bastion_extra_enis[count.index].json
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

resource "aws_iam_role_policy" "bastion_falcon_sensor" {
    count = local.has_falcon_sensor ? 1 : 0

    name   = "falcon-sensor"
    role   = aws_iam_role.bastion.id
    policy = data.aws_iam_policy_document.bastion_falcon_sensor[count.index].json
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
        events         = aws_iam_role_policy.bastion_events.id
        extra_enis     = join(" ", aws_iam_role_policy.bastion_extra_enis[*].id)
        falcon_sensor  = join(" ", aws_iam_role_policy.bastion_falcon_sensor[*].id)
        ssm            = aws_iam_role_policy_attachment.bastion_ssm.id
        ssm_parameters = aws_iam_role_policy.bastion_ssm_parameters.id
        logs           = aws_iam_role_policy.bastion_logs.id
    }

    create_duration = "10s"
}
