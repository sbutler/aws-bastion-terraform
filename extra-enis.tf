# =========================================================
# Data: Subnets
# =========================================================

data "aws_subnet" "extra_enis" {
    for_each = zipmap(
        flatten([ for o_idx, o in var.extra_enis : [ for v_idx, v in o.subnet_names : "${o_idx}.${v_idx}" ] ]),
        flatten(var.extra_enis[*].subnet_names)
    )

    tags = {
        Name = each.value
    }
}

data "aws_ec2_managed_prefix_list" "extra_enis" {
    for_each = zipmap(
        flatten([ for o_idx, o in var.extra_enis : [ for v_idx, v in o.prefix_list_names : "${o_idx}.${v_idx}" ] ]),
        flatten(var.extra_enis[*].prefix_list_names)
    )

    name = each.value
}

# =========================================================
# Data: IAM
# =========================================================

data "aws_iam_policy_document" "lambda_addExtraENIs" {
    statement {
        sid    = "Create"
        effect = "Allow"

        actions = [
            "ec2:CreateNetworkInterface",
        ]

        resources = concat(
            [
                "arn:aws:ec2:${local.region_name}:${local.account_id}:network-interface/*",
                aws_security_group.bastion.arn,
            ],
            local.extra_enis_subnet_arns,
        )

        condition {
            test     = "StringEqualsIfExists"
            variable = "aws:RequestTag/Name"

            values = [ local.extra_enis_name ]
        }

        dynamic "condition" {
            for_each = length(local.extra_enis_subnet_arns) > 0 ? [ local.extra_enis_subnet_arns ] : []

            content {
                test     = "ArnEqualsIfExists"
                variable = "ec2:Subnet"

                values = condition.value
            }
        }
    }

    statement {
        sid    = "Tags"
        effect = "Allow"

        actions = [
            "ec2:CreateTags",
            "ec2:DeleteTags",
        ]

        resources = [ "arn:aws:ec2:${local.region_name}:${local.account_id}:network-interface/*" ]
    }

    statement {
        sid    = "Limited"
        effect = "Allow"

        actions = [
            "ec2:AttachNetworkInterface",
            "ec2:DeleteNetworkInterface",
            "ec2:DescribeNetworkInterfaceAttribute",
            "ec2:ModifyNetworkInterfaceAttribute",
        ]

        resources = concat(
            [
                "arn:aws:ec2:${local.region_name}:${local.account_id}:network-interface/*",
                "arn:aws:ec2:${local.region_name}:${local.account_id}:instance/*",
                aws_security_group.bastion.arn,
            ],
            local.extra_enis_subnet_arns,
        )

        condition {
            test     = "StringEqualsIfExists"
            variable = "ec2:ResourceTag/Name"

            values = distinct([
                local.instance_name,
                local.extra_enis_name,
                local.security_group_name,
            ])
        }

        condition {
            test     = "ArnEqualsIfExists"
            variable = "ec2:InstanceProfile"

            values = [ aws_iam_instance_profile.bastion.arn ]
        }

        dynamic "condition" {
            for_each = length(local.extra_enis_subnet_arns) > 0 ? [ local.extra_enis_subnet_arns ] : []

            content {
                test     = "ArnEqualsIfExists"
                variable = "ec2:Subnet"

                values = condition.value
            }
        }
    }

    statement {
        sid    = "Global"
        effect = "Allow"

        actions = [
            "ec2:DescribeInstances",
            "ec2:DescribeNetworkInterfaces",
        ]

        resources = [ "*" ]
    }
}

# =========================================================
# Locals
# =========================================================

locals {
    extra_enis_name = "${local.name_prefix}bastion Extra ENI"

    extra_enis = [ for o_idx, o in var.extra_enis : merge(
        defaults(o, {
            description = ""
        }),
        {
            subnet_ids = { for v_idx, v in o.subnet_names : data.aws_subnet.extra_enis["${o_idx}.${v_idx}"].availability_zone => data.aws_subnet.extra_enis["${o_idx}.${v_idx}"].id }
            prefix_list_ids = [ for v_idx, v in o.prefix_list_names : data.aws_ec2_managed_prefix_list.extra_enis["${o_idx}.${v_idx}"].id ]
        }
    )]
    extra_enis_subnet_ids      = [ for s in data.aws_subnet.extra_enis: s.id ]
    extra_enis_subnet_arns     = [ for s in data.aws_subnet.extra_enis: s.arn ]
    extra_enis_prefix_list_ids = [ for p in data.aws_ec2_managed_prefix_list.extra_enis : p.id ]
    #extra_enis_vpc_ids         = distinct(flatten(local.extra_enis[*].vpc_ids))
    has_extra_enis             = length(local.extra_enis) > 0
}

# =========================================================
# Resources: addExtraENIs
# =========================================================

module "lambda_addExtraENIs" {
    source  = "terraform-aws-modules/lambda/aws"
    version = "2.4.0"

    function_name = "${local.name_prefix}bastion-addExtraENIs"
    description   = "Add extra ENIs to a bastion instance."
    handler       = "add_extra_enis.lambda_handler"
    runtime       = "python3.8"
    timeout       = 30

    environment_variables = {
        EXTRA_ENI_CONFIGS = jsonencode([ for o in local.extra_enis : {
            description = o.description
            subnet_ids  = o.subnet_ids
        }])
        EXTRA_ENI_SECURITY_GROUP_IDS = jsonencode([
            aws_security_group.bastion.id,
        ])
        EXTRA_ENI_TAGS = jsonencode(merge(
            local.default_tags,
            { Name = local.extra_enis_name }
        ))

        LOGGING_LEVEL = local.is_debug ? "DEBUG" : "INFO"
    }

    create_current_version_allowed_triggers = false
    attach_policy_jsons    = true
    number_of_policy_jsons = 1
    policy_jsons = [
        data.aws_iam_policy_document.lambda_addExtraENIs.json,
    ]

    create_package         = false
    local_existing_package = "${path.module}/lambda/addExtraENIs/dist/addExtraENIs.zip"

    allowed_triggers = {
        BastionInitStatus = {
            principal  = "events.amazonaws.com"
            source_arn = aws_cloudwatch_event_rule.lambda_addExtraENIs_BastionInitializationStatus.arn
        }
    }

    cloudwatch_logs_retention_in_days = 7
}

resource "aws_cloudwatch_event_rule" "lambda_addExtraENIs_BastionInitializationStatus" {
    name_prefix   = "${local.name_prefix}bastion-addExtraENIs-"
    description   = "Add extra bastion ENIs when the latest host status is ready."
    event_pattern = <<EOF
{
    "source": [ "bastion.aws.illinois.edu" ],
    "detail-type": [ "Bastion Initialization Status" ],
    "detail": {
        "autoScalingGroupName": [ "${local.asg_name}" ],
        "lastStatus": [ "extra-enis" ],
        "status": {
            "extra-enis": [ "finished" ]
        }
    }
}
EOF
}

resource "aws_cloudwatch_event_target" "lambda_addExtraENIs_BastionInitializationStatus" {
    rule = aws_cloudwatch_event_rule.lambda_addExtraENIs_BastionInitializationStatus.name
    arn  = module.lambda_addExtraENIs.lambda_function_arn
}
