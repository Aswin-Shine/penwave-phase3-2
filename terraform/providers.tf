# ─────────────────────────────────────────────────────────────────────────────
# Provider & Backend Configuration
#
# State backend: S3 with native locking (use_lockfile), same pattern carried
# from Phase 2. No DynamoDB table needed — Terraform 1.10+ supports S3-native
# locking via a .tflock companion object, removing a whole piece of
# infrastructure (and cost) that used to be mandatory for safe concurrent
# state access.
#
# ONE-TIME MANUAL STEP before first `terraform init`:
#   aws s3api create-bucket --bucket penwave-terraform-state-<youraccountid> \
#     --region us-east-1
#   aws s3api put-bucket-versioning --bucket penwave-terraform-state-<id> \
#     --versioning-configuration Status=Enabled
#
# Then uncomment and fill in the backend block below.
# ─────────────────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Uncomment after creating the S3 bucket (see comment above).
  # backend "s3" {
  #   bucket       = "penwave-terraform-state-<youraccountid>"
  #   key          = "phase3/terraform.tfstate"
  #   region       = "us-east-1"
  #   use_lockfile = true
  #   encrypt      = true
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Phase       = "phase3-eks"
    }
  }
}
