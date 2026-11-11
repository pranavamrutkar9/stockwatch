terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.72"
    }
  }

  # State: local by default so `plan` needs no billable resources. For a real
  # apply, use the S3 backend in backend.tf.example (approval required: S3 bucket).
}

provider "aws" {
  region = var.region

  # Guard: refuse to run against any other account.
  allowed_account_ids = var.allowed_account_ids

  default_tags {
    tags = {
      Project     = "stockwatch"
      Environment = "dr-melbourne"
      ManagedBy   = "terraform"
    }
  }
}
