# =========================================================
# Resources
# =========================================================

resource "aws_cloudwatch_log_group" "ec2_auditlog" {
    name = "/${local.loggroup_prefix}var/log/audit/audit.log"

    retention_in_days = 90
    kms_key_id        = aws_kms_key.data.arn
}

resource "aws_cloudwatch_log_group" "ec2_bootlog" {
    name = "/${local.loggroup_prefix}var/log/boot.log"

    retention_in_days = 90
    kms_key_id        = aws_kms_key.data.arn
}

resource "aws_cloudwatch_log_group" "ec2_cloudinitlog" {
    name = "/${local.loggroup_prefix}var/log/cloud-init.log"

    retention_in_days = 90
    kms_key_id        = aws_kms_key.data.arn
}

resource "aws_cloudwatch_log_group" "ec2_cron" {
    name = "/${local.loggroup_prefix}var/log/cron"

    retention_in_days = 90
    kms_key_id        = aws_kms_key.data.arn
}

resource "aws_cloudwatch_log_group" "ec2_messages" {
    name = "/${local.loggroup_prefix}var/log/messages"

    retention_in_days = 90
    kms_key_id        = aws_kms_key.data.arn
}

resource "aws_cloudwatch_log_group" "ec2_secure" {
    name = "/${local.loggroup_prefix}var/log/secure"

    retention_in_days = 90
    kms_key_id        = aws_kms_key.data.arn
}

resource "aws_cloudwatch_log_group" "ec2_ossec_alertsjson" {
    name = "/${local.loggroup_prefix}var/ossec/logs/alerts/alerts.json"

    retention_in_days = 90
    kms_key_id        = aws_kms_key.data.arn
}

resource "aws_cloudwatch_log_group" "ec2_ossec_osseclog" {
    name = "/${local.loggroup_prefix}var/ossec/logs/ossec.log"

    retention_in_days = 90
    kms_key_id        = aws_kms_key.data.arn
}
