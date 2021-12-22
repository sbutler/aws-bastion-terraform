terraform {
    required_version = "~> 1.1.2"
    required_providers {
        aws = {
            source  = "hashicorp/aws"
            version = "~> 3.70"
        }
        cloudinit = {
            source  = "hashicorp/cloudinit"
            version = "~> 2.2"
        }
        time = {
            source  = "hashicorp/time"
            version = "~> 0.7.2"
        }
        null = {
            source  = "hashicorp/null"
            version = "~> 3.1"
        }
    }

    /* CHANGEME: Uncomment to use as a standalone
    backend "s3" {
        bucket         = "deploy-bastion-CHANGEME"
        key            = "bastion/state.tfstate"
        dynamodb_table = "terraform"

        encrypt    = true

        region = "us-east-2"
    }
    */

    experiments = [ module_variable_optional_attrs ]
}

/* CHANGEME: Uncomment to use as a standalone
provider "aws" {
    region = "us-east-2"
    default_tags {
        tags = local.default_tags
    }
}
*/

locals {
    default_tags = {
        Service     = var.service
        Contact     = var.contact
        Environment = var.environment
        Project     = var.project
    }
}
