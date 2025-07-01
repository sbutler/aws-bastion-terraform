# =========================================================
# Data
# =========================================================

data "aws_iam_policy_document" "assets" {
    statement {
        sid    = "AllowSSLRequestsOnly"
        effect = "Deny"

        actions = [ "s3:*" ]

        resources = [
            aws_s3_bucket.assets.arn,
            "${aws_s3_bucket.assets.arn}/*",
        ]

        principals {
            type        = "*"
            identifiers = [ "*" ]
        }

        condition {
            test     = "Bool"
            variable = "aws:SecureTransport"

            values = [ "false" ]
        }
    }

    statement {
        sid    = "cloud-init"
        effect = "Allow"

        actions = [ "s3:GetObject*" ]

        resources = [ "${aws_s3_bucket.assets.arn}/cloud-init/*" ]

        principals {
            type        = "AWS"
            identifiers = [ "*" ]
        }

        condition {
            test     = "StringEquals"
            variable = "aws:SourceVpce"

            values = [ data.aws_vpc_endpoint.s3.id ]
        }
    }
}

# =========================================================
# Locals
# =========================================================

locals {
    assets_cloudinit = {
        "cis.sh"                    = { content_type = "text/x-shellscript" }
        "cron.sh"                   = { content_type = "text/x-shellscript" }
        "duo.sh"                    = { content_type = "text/x-shellscript" }
        "ec2logs.sh"                = { content_type = "text/x-shellscript" }
        "efs.sh"                    = { content_type = "text/cloud-boothook" }
        "extra-enis.sh"             = { content_type = "text/x-shellscript" }
        "falcon-sensor.sh"          = { content_type = "text/x-shellscript" }
        "init.sh"                   = { content_type = "text/cloud-boothook" }
        "journald-cloudwatch-logs"  = { content_type = "application/octet-stream" }
        "network.sh"                = { content_type = "text/x-shellscript" }
        "ossec.sh"                  = { content_type = "text/x-shellscript" }
        "resolv.sh"                 = { content_type = "text/x-shellscript" }
        "s3-download.sh"            = { content_type = "text/cloud-boothook" }
        "ssh.sh"                    = { content_type = "text/x-shellscript" }
        "sss.sh"                    = { content_type = "text/x-shellscript" }
        "swap.sh"                   = { content_type = "text/cloud-boothook" }
    }

    assets_extra_scripts = { for idx, s in var.cloudinit_scripts : format("script-%03d.sh", idx) => (can(regex("\n", s)) ? s : file(s))}
    assets_extra_config  = var.cloudinit_config == null ? null : "${var.cloudinit_config}\nmerge_type: 'list(append)+dict(recurse_array)+str()'"
}

# =========================================================
# Resources: Bucket
# =========================================================

resource "aws_s3_bucket" "assets" {
    bucket_prefix = "${local.name_prefix}assets-"
}

resource "aws_s3_bucket_ownership_controls" "assets" {
    bucket = aws_s3_bucket.assets.bucket

    rule {
        object_ownership = "BucketOwnerEnforced"
    }
}

resource "aws_s3_bucket_public_access_block" "assets" {
    bucket = aws_s3_bucket.assets.bucket

    block_public_acls       = true
    block_public_policy     = true
    ignore_public_acls      = true
    restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "assets" {
    bucket = aws_s3_bucket.assets.bucket
    policy = data.aws_iam_policy_document.assets.json
}

resource "aws_s3_bucket_server_side_encryption_configuration" "assets" {
    bucket = aws_s3_bucket.assets.bucket

    rule {
        apply_server_side_encryption_by_default {
            # Can't use KMS b/c we are using plain URLs and not signed URLs
            sse_algorithm = "AES256"
        }
    }
}

resource "aws_s3_bucket_versioning" "assets" {
    bucket = aws_s3_bucket.assets.bucket

    versioning_configuration {
        status = "Enabled"
    }
}

# =========================================================
# Resources: cloud-init
# =========================================================

resource "aws_s3_object" "assets_cloudinit" {
    for_each   = local.assets_cloudinit
    depends_on = [
        aws_s3_bucket_public_access_block.assets,
        aws_s3_bucket_policy.assets,
        aws_s3_bucket_server_side_encryption_configuration.assets,
        aws_s3_bucket_versioning.assets,
    ]

    bucket = aws_s3_bucket.assets.bucket
    key    = "cloud-init/${each.key}"

    source       = "${path.module}/files/cloud-init/${each.key}"
    content_type = each.value.content_type
    source_hash  = filemd5("${path.module}/files/cloud-init/${each.key}")
}

resource "aws_s3_object" "assets_extra_scripts" {
    for_each   = local.assets_extra_scripts
    depends_on = [
        aws_s3_bucket_public_access_block.assets,
        aws_s3_bucket_policy.assets,
        aws_s3_bucket_server_side_encryption_configuration.assets,
        aws_s3_bucket_versioning.assets,
    ]

    bucket = aws_s3_bucket.assets.bucket
    key    = "cloud-init/extra/${each.key}"

    content      = each.value
    content_type = "text/x-shellscript"
    source_hash  = md5(each.value)
}

resource "aws_s3_object" "assets_extra_config" {
    count      = local.assets_extra_config == null ? 0 : 1
    depends_on = [
        aws_s3_bucket_public_access_block.assets,
        aws_s3_bucket_policy.assets,
        aws_s3_bucket_server_side_encryption_configuration.assets,
        aws_s3_bucket_versioning.assets,
    ]

    bucket = aws_s3_bucket.assets.bucket
    key    = "cloud-init/extra/config.yml"

    content      = local.assets_extra_config
    content_type = "text/cloud-config"
    source_hash  = md5(local.assets_extra_config)
}
