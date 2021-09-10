# =========================================================
# Locals
# =========================================================

locals {
    ec2_log_groups = {
        "var/log/audit/audit.log" = {}
        "var/log/boot.log" = {}
        "var/log/cloud-init.log" = {}
        "var/log/cron" = {}
        "var/log/messages" = {}
        "var/log/secure" = {}
        "var/log/sudo.log" = {}
        "var/ossec/logs/alerts/alerts.json" = {}
        "var/ossec/logs/ossec.log" = {}
    }
}

# =========================================================
# Resources
# =========================================================

resource "aws_cloudwatch_log_group" "ec2" {
    for_each = local.ec2_log_groups

    name = "/${local.loggroup_prefix}${each.key}"

    retention_in_days = 90
    kms_key_id        = aws_kms_key.data.arn
}
