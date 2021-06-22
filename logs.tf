# =========================================================
# Resources
# =========================================================

resource "aws_cloudwatch_log_group" "ec2_auditlog" {
    name = "/${local.name_prefix}bastion/var/log/audit/audit.log"

    retention_in_days = 90
}

resource "aws_cloudwatch_log_group" "ec2_bootlog" {
    name = "/${local.name_prefix}bastion/var/log/boot.log"

    retention_in_days = 90
}

resource "aws_cloudwatch_log_group" "ec2_cloudinitlog" {
    name = "/${local.name_prefix}bastion/var/log/cloud-init.log"

    retention_in_days = 90
}

resource "aws_cloudwatch_log_group" "ec2_cron" {
    name = "/${local.name_prefix}bastion/var/log/cron"

    retention_in_days = 90
}

resource "aws_cloudwatch_log_group" "ec2_messages" {
    name = "/${local.name_prefix}bastion/var/log/messages"

    retention_in_days = 90
}

resource "aws_cloudwatch_log_group" "ec2_secure" {
    name = "/${local.name_prefix}bastion/var/log/secure"

    retention_in_days = 90
}

resource "aws_cloudwatch_log_group" "ec2_ossec_alertsjson" {
    name = "/${local.name_prefix}bastion/var/ossec/logs/alerts/alerts.json"

    retention_in_days = 90
}

resource "aws_cloudwatch_log_group" "ec2_ossec_osseclog" {
    name = "/${local.name_prefix}bastion/var/ossec/logs/ossec.log"

    retention_in_days = 90
}
