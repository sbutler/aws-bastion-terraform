# =========================================================
# Data: Subnets
# =========================================================

data "aws_subnet" "extra_enis" {
    for_each = zipmap(
        flatten([ for o_name, o in var.extra_enis : [ for v_idx, v in o.subnets : "${o_name}.${v_idx}" ] ]),
        flatten([ for o_name, o in var.extra_enis: o.subnets ])
    )

    id   = can(regex("^subnet-([a-f0-9]{8}|[a-f0-9]{17})$", each.value)) ? each.value : null
    tags = can(regex("^subnet-([a-f0-9]{8}|[a-f0-9]{17})$", each.value)) ? null : {
        Name = each.value
    }
}

data "aws_ec2_managed_prefix_list" "extra_enis" {
    for_each = zipmap(
        flatten([ for o_name, o in var.extra_enis : [ for v_idx, v in o.prefix_lists : "${o_name}.${v_idx}" ] ]),
        flatten([ for o_name, o in var.extra_enis : o.prefix_lists ])
    )

    id   = can(regex("^pl-([a-f0-9]{8}|[a-f0-9]{17})$", each.value)) ? each.value : null
    name = can(regex("^pl-([a-f0-9]{8}|[a-f0-9]{17})$", each.value)) ? null : each.value
}

data "aws_vpc" "extra_enis" {
    for_each = { for o_name, o in var.extra_enis : o_name => data.aws_subnet.extra_enis["${o_name}.0"].vpc_id }

    id = each.value
}

data "aws_security_group" "extra_enis" {
    for_each = zipmap(
        flatten([ for o_name, o in var.extra_enis : [ for s_idx, s in o.security_groups : "${o_name}.${s_idx}" ] ]),
        flatten([ for o_name, o in var.extra_enis : o.security_groups ])
    )

    id   = can(regex("^sg-([a-f0-9]{8}|[a-f0-9]{17})$", each.value)) ? each.value : null
    name = can(regex("^sg-([a-f0-9]{8}|[a-f0-9]{17})$", each.value)) ? null : each.value

    vpc_id = data.aws_vpc.extra_enis[split(".", each.key)[0]].id
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
            [ "arn:aws:ec2:${local.region_name}:${local.account_id}:network-interface/*" ],
            local.extra_enis_subnet_arns,
            [ for s in values(aws_security_group.extra_enis_default) : s.arn ],
            [ for s in values(data.aws_security_group.extra_enis) : s.arn ],
        )

        condition {
            test     = "StringEqualsIfExists"
            variable = "aws:RequestTag/Name"

            values = [ for o_name, n in local.extra_enis_names : n.eni ]
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
            ],
            local.extra_enis_subnet_arns,
            [ for s in values(aws_security_group.extra_enis_default) : s.arn ],
            [ for s in values(data.aws_security_group.extra_enis) : s.arn ],
        )

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
    extra_enis_names = { for o_name in keys(var.extra_enis) : o_name => {
        default_security_group = "${local.name} Extra ENI Default (${o_name})"
        eni                    = "${local.name} Extra ENI (${o_name})"
    }}

    extra_enis = { for o_name, o in var.extra_enis : o_name => merge(
        o,
        {
            name                      = local.extra_enis_names[o_name].eni
            subnet_ids                = { for v_idx, v in o.subnets : data.aws_subnet.extra_enis["${o_name}.${v_idx}"].availability_zone => data.aws_subnet.extra_enis["${o_name}.${v_idx}"].id }
            prefix_list_ids           = [ for v_idx, v in o.prefix_lists : data.aws_ec2_managed_prefix_list.extra_enis["${o_name}.${v_idx}"].id ]
            default_security_group_id = aws_security_group.extra_enis_default[o_name].id
            security_group_ids        = concat(
                [ aws_security_group.extra_enis_default[o_name].id ],
                [ for s_name, s in data.aws_security_group.extra_enis : s.id if startswith(s_name, "${o_name}.") ],
            )
        }
    )}
    extra_enis_subnet_ids       = [ for s in data.aws_subnet.extra_enis: s.id ]
    extra_enis_subnet_arns      = [ for s in data.aws_subnet.extra_enis: s.arn ]
    extra_enis_prefix_list_ids  = [ for p in data.aws_ec2_managed_prefix_list.extra_enis : p.id ]
    extra_enis_prefix_list_arns = [ for p in data.aws_ec2_managed_prefix_list.extra_enis : p.arn ]
    has_extra_enis             = length(var.extra_enis) > 0
}

# =========================================================
# Resources: addExtraENIs
# =========================================================

resource "aws_security_group" "extra_enis_default" {
    for_each = { for o_name, o in var.extra_enis : o_name => {
        vpc_id          = data.aws_vpc.extra_enis[o_name].id
        prefix_list_ids = [ for v_idx, v in o.prefix_lists : data.aws_ec2_managed_prefix_list.extra_enis["${o_name}.${v_idx}"].id ]
        name_tag        = local.extra_enis_names[o_name].default_security_group
    }}

    name_prefix = local.name_prefix
    description = "Bastion Extra ENI default group."
    vpc_id      = each.value.vpc_id

    egress {
        from_port = 0
        to_port   = 0
        protocol  = "-1"

        prefix_list_ids = each.value.prefix_list_ids
        self            = true
    }

    tags = {
        Name = each.value.name_tag
    }
}

module "lambda_addExtraENIs" {
    source  = "terraform-aws-modules/lambda/aws"
    version = "4.18.0"

    function_name = "${local.name_prefix}addExtraENIs"
    description   = "Add extra ENIs to a bastion instance."
    handler       = "add_extra_enis.lambda_handler"
    runtime       = "python3.10"
    timeout       = 30

    environment_variables = {
        EXTRA_ENI_CONFIGS = jsonencode({ for o_name, o in local.extra_enis : o_name => {
            name               = o.name
            description        = o.description
            subnet_ids         = o.subnet_ids
            security_group_ids = o.security_group_ids
        }})
        EXTRA_ENI_TAGS = jsonencode(local.default_tags)

        LOGGING_LEVEL = local.is_debug ? "DEBUG" : "INFO"
    }

    create_current_version_allowed_triggers = false
    role_name              = "${local.name_prefix}addExtraENIs-${local.region_name}"
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
    cloudwatch_logs_kms_key_id        = aws_kms_key.data.arn
}

resource "aws_cloudwatch_event_rule" "lambda_addExtraENIs_BastionInitializationStatus" {
    name_prefix   = "${local.name_prefix}addExtraENIs-"
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
