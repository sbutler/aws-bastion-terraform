# =========================================================
# Data
# =========================================================

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

locals {
    region_name = data.aws_region.current.name
    account_id  = data.aws_caller_identity.current.account_id
}

# =========================================================
# Data: IAM
# =========================================================

data "aws_iam_policy_document" "ec2_assume_role" {
    statement {
        effect  = "Allow"
        actions = [ "sts:AssumeRole" ]
        principals {
            type        = "Service"
            identifiers = [ "ec2.amazonaws.com" ]
        }
    }
}

# =========================================================
# Data: VPC
# =========================================================

data "aws_subnet" "public" {
    count = length(var.public_subnets)

    state = "available"
    tags = {
        Name = var.public_subnets[count.index]
    }
}

data "aws_subnet" "internal" {
    count = length(var.internal_subnets)

    state = "available"
    tags = {
        Name = var.internal_subnets[count.index]
    }
}

data "aws_vpc_endpoint" "s3" {
    vpc_id       = local.vpc_id
    service_name = "com.amazonaws.${local.region_name}.s3"
}

locals {
    vpc_id          = data.aws_subnet.public[0].vpc_id
    internal_vpc_id = data.aws_subnet.internal[0].vpc_id

    public_subnet_ids   = data.aws_subnet.public[*].id
    internal_subnet_ids = data.aws_subnet.internal[*].id
}

# =========================================================
# Locals
# =========================================================

locals {
    name_prefix = "${var.project}-"
    is_debug    = var.environment != "prod"

    falcon_sensor_package_match = var.falcon_sensor_package == null ? {
        bucket = null
        key    = null
    } : regex("^s3://(?P<bucket>[a-z0-9][a-z0-9.-]+[a-z0-9.])/(?P<key>.+\\.rpm)$", var.falcon_sensor_package)
    falcon_sensor_package_bucket   = lookup(local.falcon_sensor_package_match, "bucket", null)
    falcon_sensor_package_key      = lookup(local.falcon_sensor_package_match, "key", null)
    has_falcon_sensor              = local.falcon_sensor_package_bucket != null && local.falcon_sensor_package_key != null
    falcon_sensor_parameter_prefix = "${local.name_prefix}bastion/falcon-sensor/"

    loggroup_prefix        = "${local.name_prefix}bastion/"
    metrics_namespace      = "${local.name_prefix}bastion"
    sss_parameter_prefix   = "${local.name_prefix}bastion/sss/"
    ssh_parameter_prefix   = "${local.name_prefix}bastion/ssh/"
    ossec_parameter_prefix = "${local.name_prefix}bastion/ossec/"
}
