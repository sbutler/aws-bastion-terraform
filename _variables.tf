# =========================================================
# Cloud First
# =========================================================

variable "service" {
    type        = string
    description = "Service name (match Service Catalog where possible)."
}

variable "contact" {
    type        = string
    description = "Service email address."
}

variable "data_classification" {
    type        = string
    description = "Public, Internal, Sensitive, or HighRisk (choose the most rigorous standard that applies)."
}

variable "environment" {
    type        = string
    description = "Environment name (prod, test, dev, or poc)."
    default     = ""

    validation {
        condition     = var.environment == "" || contains(["prod", "test", "dev", "poc"], var.environment)
        error_message = "Value must be one of: prod, test, dev, or poc."
    }
}

variable "project" {
    type        = string
    description = "Name of the project for this bastion."
}

# =========================================================
# Bastion
# =========================================================

variable "instance_type" {
    type        = string
    description = "Bastion instance type."
    default     = "t3.micro"
}

variable "key_name" {
    type        = string
    description = "SSH key name to use for instances."
}

variable "enhanced_monitoring" {
    type        = bool
    description = "Use enahanced/detailed monitoring on supported resources."
    default     = false
}

variable "admin_groups" {
    type        = list(string)
    description = "List of groups allowed to admin the bastion host."
}

variable "allow_groups" {
    type        = list(string)
    description = "List of groups allowed to SSH into the bastion host. Admin groups are implicitly included."
    default     = []
}

variable "public_subnets" {
    type        = list(string)
    description = "Subnet names for public access where the primary IP will be."
}

variable "internal_subnets" {
    type        = list(string)
    description = "Subnet names to use for internal resources unreachable from outside the VPC."
}

variable "extra_enis" {
    type        = list(object({
                    subnet_names      = list(string)
                    description       = optional(string)
                    prefix_list_names = list(string)
                }))
    description = "List of extra ENIs to attach to the bastion host. You can configure what routes this ENI is used for by provising prefix list IDs and/or VPC IDs."
    default = []

    validation {
        condition     = alltrue([ for o in var.extra_enis : length(o.subnet_names) > 0 ])
        error_message = "You must specify a subnet name for each availability zone."
    }

    validation {
        condition     = alltrue([ for o in var.extra_enis : length(o.prefix_list_names) > 0 ])
        error_message = "You must specify a prefix list name for each ENI."
    }
}
