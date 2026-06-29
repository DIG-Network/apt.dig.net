# Terraform + provider version pins. us-east-1 is required: CloudFront only reads ACM
# certs from us-east-1, and the rest of the DIG ecosystem deploys there (see the
# dig-deploy-targets memory / SYSTEM.md).
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}
