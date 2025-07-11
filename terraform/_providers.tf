terraform {
    required_version = "~> 1.10.0"
    required_providers {
        aws = {
            source  = "hashicorp/aws"
            version = "~> 6.0"
        }
        cloudinit = {
            source  = "hashicorp/cloudinit"
            version = "~> 2.3"
        }
        time = {
            source  = "hashicorp/time"
            version = "~> 0.13.1"
        }
        null = {
            source  = "hashicorp/null"
            version = "~> 3.2.1"
        }
    }

    /* CHANGEME: Uncomment to use as a standalone
    backend "s3" {
        bucket = "deploy-bastion-CHANGEME"
        key    = "bastion/state.tfstate"

        encrypt    = true

        region = "us-east-2"
    }
    */
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
