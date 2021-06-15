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