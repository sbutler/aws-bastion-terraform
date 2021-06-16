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
# Resources: Bucket
# =========================================================

resource "aws_s3_bucket" "assets" {
    bucket_prefix = "${local.name_prefix}bastion-assets-"

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

resource "aws_s3_bucket_object" "assets_cloudinit_ec2logsyml" {
    bucket = aws_s3_bucket.assets.bucket
    key    = "cloud-init/ec2logs.yml"

    source       = "${path.module}/files/cloud-init/ec2logs.yml"
    acl          = "bucket-owner-full-control"
    content_type = "text/yaml"
    etag         = filemd5("${path.module}/files/cloud-init/ec2logs.yml")
}

resource "aws_s3_bucket_object" "assets_cloudinit_efssh" {
    bucket = aws_s3_bucket.assets.bucket
    key    = "cloud-init/efs.sh"

    source       = "${path.module}/files/cloud-init/efs.sh"
    acl          = "bucket-owner-full-control"
    content_type = "text/x-sh"
    etag         = filemd5("${path.module}/files/cloud-init/efs.sh")
}

resource "aws_s3_bucket_object" "assets_cloudinit_extraenissh" {
    bucket = aws_s3_bucket.assets.bucket
    key    = "cloud-init/extra-enis.sh"

    source       = "${path.module}/files/cloud-init/extra-enis.sh"
    acl          = "bucket-owner-full-control"
    content_type = "text/x-sh"
    etag         = filemd5("${path.module}/files/cloud-init/extra-enis.sh")
}

resource "aws_s3_bucket_object" "assets_cloudinit_falconsensorsh" {
    bucket = aws_s3_bucket.assets.bucket
    key    = "cloud-init/falcon-sensor.sh"

    source       = "${path.module}/files/cloud-init/falcon-sensor.sh"
    acl          = "bucket-owner-full-control"
    content_type = "text/x-sh"
    etag         = filemd5("${path.module}/files/cloud-init/falcon-sensor.sh")
}

resource "aws_s3_bucket_object" "assets_cloudinit_initsh" {
    bucket = aws_s3_bucket.assets.bucket
    key    = "cloud-init/init.sh"

    source       = "${path.module}/files/cloud-init/init.sh"
    acl          = "bucket-owner-full-control"
    content_type = "text/x-sh"
    etag         = filemd5("${path.module}/files/cloud-init/init.sh")
}

resource "aws_s3_bucket_object" "assets_cloudinit_s3downloadsh" {
    bucket = aws_s3_bucket.assets.bucket
    key    = "cloud-init/s3-download.sh"

    source       = "${path.module}/files/cloud-init/s3-download.sh"
    acl          = "bucket-owner-full-control"
    content_type = "text/x-sh"
    etag         = filemd5("${path.module}/files/cloud-init/s3-download.sh")
}

resource "aws_s3_bucket_object" "assets_cloudinit_sshsh" {
    bucket = aws_s3_bucket.assets.bucket
    key    = "cloud-init/ssh.sh"

    source       = "${path.module}/files/cloud-init/ssh.sh"
    acl          = "bucket-owner-full-control"
    content_type = "text/x-sh"
    etag         = filemd5("${path.module}/files/cloud-init/ssh.sh")
}

resource "aws_s3_bucket_object" "assets_cloudinit_ssssh" {
    bucket = aws_s3_bucket.assets.bucket
    key    = "cloud-init/sss.sh"

    source       = "${path.module}/files/cloud-init/sss.sh"
    acl          = "bucket-owner-full-control"
    content_type = "text/x-sh"
    etag         = filemd5("${path.module}/files/cloud-init/sss.sh")
}

resource "aws_s3_bucket_object" "assets_cloudinit_yumcronyml" {
    bucket = aws_s3_bucket.assets.bucket
    key    = "cloud-init/yumcron.yml"

    source       = "${path.module}/files/cloud-init/yumcron.yml"
    acl          = "bucket-owner-full-control"
    content_type = "text/yaml"
    etag         = filemd5("${path.module}/files/cloud-init/yumcron.yml")
}
