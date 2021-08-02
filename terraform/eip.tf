# =========================================================
# Data
# =========================================================

data "aws_iam_policy_document" "lambda_associateEIP" {
    statement {
        sid    = "Global"
        effect = "Allow"

        actions = [
            "ec2:DescribeAddresses",
            "ec2:DescribeInstances",
            "ec2:DescribeNetworkInterfaces",
        ]

        resources = [ "*" ]
    }

    statement {
        sid = "Limited"
        effect = "Allow"

        actions = [
            "ec2:AssociateAddress",
            "ec2:DisassociateAddress",
        ]

        resources = [
            "arn:aws:ec2:${local.region_name}:${local.account_id}:elastic-ip/${aws_eip.bastion.id}",
            "arn:aws:ec2:${local.region_name}:${local.account_id}:instance/*",
            "arn:aws:ec2:${local.region_name}:${local.account_id}:network-interface/*",
        ]

        condition {
            test     = "StringEqualsIfExists"
            variable = "ec2:ResourceTag/aws:autoscaling:groupName"

            values = [ local.asg_name ]
        }

        condition {
            test     = "ArnEqualsIfExists"
            variable = "ec2:Subnet"

            values = formatlist(
                "arn:aws:ec2:%s:%s:subnet/%s",
                local.region_name,
                local.account_id,
                local.public_subnet_ids,
            )
        }
    }
}

# =========================================================
# Resources: EIP
# =========================================================

resource "aws_eip" "bastion" {
    vpc = true

    tags = {
        Name = local.name
    }

    lifecycle {
        #prevent_destroy = true
    }
}

# =========================================================
# Resources: associateEIP
# =========================================================

module "lambda_associateEIP" {
    source  = "terraform-aws-modules/lambda/aws"
    version = "2.4.0"

    function_name = "${local.name_prefix}associateEIP"
    description   = "Associate an EIP with a bastion instance."
    handler       = "associate_eip.lambda_handler"
    runtime       = "python3.8"
    timeout       = 30

    environment_variables = {
        EIP_ALLOCATION_ID = aws_eip.bastion.id

        LOGGING_LEVEL = local.is_debug ? "DEBUG" : "INFO"
    }

    create_current_version_allowed_triggers = false
    attach_policy_jsons    = true
    number_of_policy_jsons = 1
    policy_jsons = [
        data.aws_iam_policy_document.lambda_associateEIP.json,
    ]

    create_package         = false
    local_existing_package = "${path.module}/lambda/associateEIP/dist/associateEIP.zip"

    allowed_triggers = {
        BastionInitStatus = {
            principal  = "events.amazonaws.com"
            source_arn = aws_cloudwatch_event_rule.lambda_associateEIP_BastionInitializationStatus.arn
        }
    }

    cloudwatch_logs_retention_in_days = 7
    cloudwatch_logs_kms_key_id        = aws_kms_key.data.arn
}

resource "aws_cloudwatch_event_rule" "lambda_associateEIP_BastionInitializationStatus" {
    name_prefix   = "${local.name_prefix}associateEIP-"
    description   = "Associate the bastion EIP when the latest host status is ready."
    event_pattern = <<EOF
{
    "source": [ "bastion.aws.illinois.edu" ],
    "detail-type": [ "Bastion Initialization Status" ],
    "detail": {
        "autoScalingGroupName": [ "${local.asg_name}" ],
        "lastStatus": [ "duo", "efs", "network", "ssh", "sss" ],
        "status": {
            "duo": [ "finished" ],
            "efs": [ "finished" ],
            "network": [ "finished" ],
            "ssh": [ "finished" ],
            "sss": [ "finished" ]
        }
    }
}
EOF
}

resource "aws_cloudwatch_event_target" "lambda_associateEIP_BastionInitializationStatus" {
    rule = aws_cloudwatch_event_rule.lambda_associateEIP_BastionInitializationStatus.name
    arn  = module.lambda_associateEIP.lambda_function_arn
}
