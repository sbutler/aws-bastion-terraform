# =========================================================
# Data
# =========================================================

data "aws_iam_policy_document" "kms_data" {
    statement {
        sid    = "Enable IAM User Permissions"
        effect = "Allow"

        actions = [ "kms:*" ]

        resources = [ "*" ]

        principals {
            type        = "AWS"
            identifiers = [ "arn:aws:iam::${local.account_id}:root" ]
        }
    }

    statement {
        sid    = "CloudWatch Logs"
        effect = "Allow"

        actions = [
            "kms:ReEncrypt*",
            "kms:GenerateDataKey*",
            "kms:Encrypt*",
            "kms:Describe*",
            "kms:Decrypt*",
        ]

        resources = [ "*" ]

        principals {
            type        = "Service"
            identifiers = [ "logs.${local.region_name}.amazonaws.com" ]
        }

        condition {
            test      = "ArnLike"
            variable = "kms:EncryptionContext:aws:logs:arn"

            values = [
                "arn:aws:logs:${local.region_name}:${local.account_id}:log-group:/${local.loggroup_prefix}*",
                "arn:aws:logs:${local.region_name}:${local.account_id}:log-group:/${local.loggroup_prefix}*:*",
                "arn:aws:logs:${local.region_name}:${local.account_id}:log-group:/aws/lambda/${local.name_prefix}bastion-*",
                "arn:aws:logs:${local.region_name}:${local.account_id}:log-group:/aws/lambda/${local.name_prefix}bastion-*:*",
            ]
        }
    }

    statement {
        sid = "EFS"
        effect = "Allow"

        actions = [
            "kms:Encrypt",
            "kms:Decrypt",
            "kms:ReEncrypt*",
            "kms:GenerateDataKey*",
            "kms:CreateGrant",
            "kms:DescribeKey",
        ]

        resources = [ "*" ]

        principals {
            type        = "AWS"
            identifiers = [ "*" ]
        }

        condition {
            test     = "StringEquals"
            variable = "kms:CallerAccount"

            values   = [ local.account_id ]
        }
        condition {
            test     = "StringEquals"
            variable = "kms:ViaService"

            values   = [ "elasticfilesystem.${local.region_name}.amazonaws.com" ]
        }
    }

    statement {
        sid    = "EBS"
        effect = "Allow"

        actions = [
            "kms:Encrypt",
            "kms:Decrypt",
            "kms:ReEncrypt*",
            "kms:GenerateDataKey*",
            "kms:CreateGrant",
            "kms:DescribeKey",
        ]

        resources = [ "*" ]

        principals {
            type        = "AWS"
            identifiers = [ "*" ]
        }

        condition {
            test     = "StringEquals"
            variable = "kms:CallerAccount"

            values   = [ local.account_id ]
        }
        condition {
            test     = "StringEquals"
            variable = "kms:ViaService"

            values   = [ "ec2.${local.region_name}.amazonaws.com" ]
        }
    }
}

# =========================================================
# Resources
# =========================================================

resource "aws_kms_key" "data" {
    description = "${var.service} bastion host data key."

    policy = data.aws_iam_policy_document.kms_data.json

    deletion_window_in_days = 7
    enable_key_rotation     = true
}

resource "aws_kms_alias" "data" {
    name          = "alias/${local.name_prefix}bastion/data"
    target_key_id = aws_kms_key.data.id
}
