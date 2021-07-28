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
        "duo.sh"           = { content_type = "text/x-sh" }
        "ec2logs.yml"      = { content_type = "text/yaml" }
        "efs.sh"           = { content_type = "text/x-sh" }
        "extra-enis.sh"    = { content_type = "text/x-sh" }
        "falcon-sensor.sh" = { content_type = "text/x-sh" }
        "init.sh"          = { content_type = "text/x-sh" }
        "ossec.sh"         = { content_type = "text/x-sh" }
        "s3-download.sh"   = { content_type = "text/x-sh" }
        "ssh.sh"           = { content_type = "text/x-sh" }
        "sss.sh"           = { content_type = "text/x-sh" }
        "yumcron.yml"      = { content_type = "text/yaml" }
    }
}
# =========================================================
# Resources: Bucket
# =========================================================

resource "aws_s3_bucket" "assets" {
    bucket_prefix = "${local.name_prefix}assets-"

    acl = "private"
    versioning {
        enabled = true
    }
    server_side_encryption_configuration {
        rule {
            apply_server_side_encryption_by_default {
                # Can't use KMS b/c we are using plain URLs and not signed URLs
                sse_algorithm = "AES256"
            }
        }
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

# =========================================================
# Resources: cloud-init
# =========================================================

resource "aws_s3_bucket_object" "assets_cloudinit" {
    for_each = local.assets_cloudinit

    bucket = aws_s3_bucket.assets.bucket
    key    = "cloud-init/${each.key}"

    source       = "${path.module}/files/cloud-init/${each.key}"
    acl          = "bucket-owner-full-control"
    content_type = each.value.content_type
    etag         = filemd5("${path.module}/files/cloud-init/${each.key}")
}
