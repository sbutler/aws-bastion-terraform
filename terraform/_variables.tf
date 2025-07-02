# =========================================================
# Cloud First
# =========================================================

variable "service" {
    type        = string
    description = "Service Catalog name for these resources."
}

variable "contact" {
    type        = string
    description = "Service email address."
}

variable "data_classification" {
    type        = string
    description = "Data Classification value for what's stored and available through this host."

    validation {
        condition = contains(["Public", "Internal", "Sensitive", "HighRisk"], var.data_classification)
        error_message = "Must be one of: Public, Internal, Sensitive, or HighRisk."
    }
}

variable "environment" {
    type        = string
    description = "Environment name (prod, test, dev, or poc)."
    default     = ""

    validation {
        condition     = var.environment == "" || contains(["prod", "production", "test", "dev", "development", "devtest", "poc"], lower(var.environment))
        error_message = "Value must be one of: prod, production, test, dev, development, devtest, or poc."
    }
}

variable "project" {
    type        = string
    description = "Project name within the service. This is used as part of resource names, so must be a simple alpha-numeric string."
    default     = "bastion"

    validation {
        condition     = can(regex("^[a-zA-Z][a-zA-Z0-9-]+[a-zA-Z0-9]$", var.project))
        error_message = "Must start with a letter (a-z), end with a letter or number, and contain only letters, numbers, and dashes."
    }
}

# =========================================================
# Bastion
# =========================================================

variable "hostname" {
    type        = string
    description = "Hostname of the bastion host that you will associate with the IP."

    validation {
        condition     = can(regex("^[a-zA-Z0-9]([a-zA-Z0-9.-]{0,61}[a-zA-Z0-9])?\\.[a-zA-Z]{2,}$", var.hostname))
        error_message = "The value must be a valid hostname."
    }
}

variable "instance_type" {
    type        = string
    description = "Type of the instance to launch, which affects cost and features."
    default     = "t3.micro"
}

variable "key_name" {
    type        = string
    description = "EC2 SSH KeyPair for allowing access via the builtin account (ec2-user)."
}

variable "enhanced_monitoring" {
    type        = bool
    description = "Use enahanced/detailed monitoring on supported resources."
    default     = false
}

variable "falcon_sensor_package" {
    type        = string
    description = "S3 URL (s3://bucket/path/to/sensor.rpm) to download the CrowdStrike Falcon Sensor."
    default     = null

    validation {
        condition     = var.falcon_sensor_package == null || can(regex("^s3://(?P<bucket>[a-z0-9][a-z0-9.-]+[a-z0-9.])/(?P<key>.+\\.rpm)$", var.falcon_sensor_package))
        error_message = "The S3 URL must be null or of the form \"s3://bucket/path/to/sensor.rpm\"."
    }
}

variable "shell_idle_timeout" {
    type        = number
    description = "Number of seconds before an idle shell is disconnected."
    default     = 900

    validation {
        condition     = var.shell_idle_timeout >= 0
        error_message = "Value must be positive or 0."
    }
}

variable "login_banner" {
    type        = string
    description = "Message to display before a user logs into the bastion host."
    default = <<HERE
====================================================================
| This system is for the use of authorized users only.  Usage of   |
| this system may be monitored and recorded by system personnel.   |
|                                                                  |
| Anyone using this system expressly consents to such monitoring   |
| and is advised that if such monitoring reveals possible          |
| evidence of criminal activity, system personnel may provide the  |
| evidence from such monitoring to law enforcement officials.      |
====================================================================
HERE
}

variable "cloudinit_scripts" {
    type        = list(string)
    description = "List of script filenames or content to be run as part of the Cloud-Init process."
    default     = []
}

variable "cloudinit_config" {
    type        = string
    description = "YAML Cloud-Init config that will be merged with the default configs."
    default     = null

    validation {
        condition     = var.cloudinit_config == null || can(regex("^#cloud-config\\s*\\n", var.cloudinit_config))
        error_message = "Cloud-Init config must begin with '#cloud-config'."
    }
}

# =========================================================
# Networking
# =========================================================

variable "allowed_cidrs" {
    type        = map(object({
                    ipv4 = optional(list(string))
                    ipv6 = optional(list(string))
                }))
    description = "CIDRs allowed to SSH to the bastion host."
    default     = { all = { ipv4 = [ "0.0.0.0/0" ], ipv6 = [ "::/0" ] } }
}

variable "allowed_cidrs_codebuild" {
    type        = list(string)
    description = "CIDRs allowed to SSH to the bastion host (only used for CodeBuild deployments)."
    default     = null
}

variable "public_subnets" {
    type        = list(string)
    description = "Subnet names for public access where the primary IP will be."

    validation {
        condition     = length(var.public_subnets) > 0
        error_message = "You must specify at least one public subnet."
    }

    validation {
        condition     = alltrue([ for s in var.public_subnets : length(s) > 0 ])
        error_message = "The value cannot be empty."
    }
}

variable "internal_subnets" {
    type        = list(string)
    description = "Subnet names to use for internal resources unreachable from outside the VPC."

    validation {
        condition     = length(var.internal_subnets) > 0
        error_message = "You must specify at least one public subnet."
    }

    validation {
        condition     = alltrue([ for s in var.internal_subnets : length(s) > 0 ])
        error_message = "The value cannot be empty."
    }
}

variable "extra_security_groups" {
    type        = list(string)
    description = "Extra security groups (name or ID) to add to the bastion instance. Default limit is 4 extra groups, but you can request an increase from AWS."
    default     = []

    validation {
        condition     = alltrue([ for g in var.extra_security_groups : length(g) > 0 ])
        error_message = "The value cannot be empty."
    }
}

variable "extra_enis" {
    type        = map(object({
                    subnets         = list(string)
                    description     = optional(string, "")
                    prefix_lists    = list(string)
                    security_groups = optional(list(string), [])
                }))
    description = "List of extra ENIs to attach to the bastion host. You can configure what routes this ENI is used for by provising prefix list names or IDs."
    default = {}

    validation {
        condition     = alltrue([ for o in values(var.extra_enis) : length(o.subnets) > 0 ])
        error_message = "You must specify a subnet name or ID for each availability zone."
    }

    validation {
        condition     = alltrue([ for o in values(var.extra_enis) : length(o.prefix_lists) > 0 ])
        error_message = "You must specify a prefix list name or ID for each ENI."
    }
}

variable "extra_efs" {
    type        = map(object({
        filesystem_id = string
        mount_target  = optional(string)
        options       = optional(string, "tls,noresvport")
    }))
    description = "Map of extra EFS's to mount on the bastion host. The key is used as the name for the default mount point (/mnt/$name), and must not start with 'bastion-'."
    default     = {}

    validation {
        condition     = alltrue([ for k in keys(var.extra_efs) : substr(k, 0, 8) != "bastion-" ])
        error_message = "EFS names must not start with 'bastion-'."
    }

    validation {
        condition     = alltrue([ for k in keys(var.extra_efs) : can(regex("^[a-zA-Z0-9_-]+$", k)) ])
        error_message = "EFS names must be only letters, numbers, underscores, and dashes."
    }
}

# =========================================================
# Patching
# =========================================================

variable "ssm_maintenance_window_scanning" {
    type        = string
    description = "When to start the 1hour maintenance window for baseline scanning."
    default     = "cron(30 4 ? * SUN-FRI *)"
}

variable "ssm_maintenance_window_patching" {
    type        = string
    description = "When to start the 3hour maintenance window for baseline patching."
    default     = "cron(30 4 ? * SAT *)"
}
