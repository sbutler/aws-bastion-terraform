# Partial provider used during codebuild

terraform {
    backend "s3" {
        encrypt = true
    }
}

provider "aws" {
    default_tags {
        tags = local.default_tags
    }
}
