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

    id   = local.public_subnet_is_id[count.index] ? var.public_subnets[count.index] : null
    tags = local.public_subnet_is_id[count.index] ? null : {
        Name = var.public_subnets[count.index]
    }
}

data "aws_subnet" "internal" {
    count = length(var.internal_subnets)

    state = "available"

    id   = local.internal_subnet_is_id[count.index] ? var.internal_subnets[count.index] : null
    tags = local.internal_subnet_is_id[count.index] ? null : {
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
    public_subnet_is_id = [ for s in var.public_subnets : can(regex("^subnet-([a-f0-9]{8}|[a-f0-9]{17})$", s)) ]

    internal_subnet_ids   = data.aws_subnet.internal[*].id
    internal_subnet_is_id = [ for s in var.internal_subnets : can(regex("^subnet-([a-f0-9]{8}|[a-f0-9]{17})$", s)) ]
}

# =========================================================
# Data: Extra EFS
# =========================================================

data "aws_efs_file_system" "extra" {
    count = length(local.extra_efs)

    file_system_id = values(local.extra_efs)[count.index].filesystem_id
}

# =========================================================
# Locals
# =========================================================

locals {
    name        = var.project
    name_prefix = "${local.name}-"
    is_debug    = !contains(["prod", "production"], lower(var.environment))

    falcon_sensor_package_match = var.falcon_sensor_package == null ? {
        bucket = null
        key    = null
    } : regex("^s3://(?P<bucket>[a-z0-9][a-z0-9.-]+[a-z0-9.])/(?P<key>.+\\.rpm)$", var.falcon_sensor_package)
    falcon_sensor_package_bucket   = lookup(local.falcon_sensor_package_match, "bucket", null)
    falcon_sensor_package_key      = lookup(local.falcon_sensor_package_match, "key", null)
    has_falcon_sensor              = local.falcon_sensor_package_bucket != null && local.falcon_sensor_package_key != null
    falcon_sensor_parameter_prefix = "${local.name}/falcon-sensor/"

    extra_efs = { for k, v in var.extra_efs : k => merge(
        v,
        { mount_target = v.mount_target == null ? "/mnt/${k}" : v.mount_target }
    ) }

    loggroup_prefix          = "${local.name}/"
    metrics_namespace        = "${local.name}"
    cron_parameter_prefix    = "${local.name}/cron/"
    duo_parameter_prefix     = "${local.name}/duo/"
    sss_parameter_prefix     = "${local.name}/sss/"
    ssh_parameter_prefix     = "${local.name}/ssh/"
    ossec_parameter_prefix   = "${local.name}/ossec/"
    outputs_parameter_prefix = "${local.name}/outputs/"
}
