terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Remote state in S3 — see infra/DEPLOYMENT_MANUAL.md "Step 1" for AWS CLI setup, then
  # uncomment the backend block below. bucket must match the created bucket; region must
  # match the bucket's region. If you already ran terraform init with local state, use:
  #   terraform init -migrate-state
  #
  backend "s3" {
    bucket         = "nanobot-tfstate-049365253529"
    key            = "nanobot/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "nanobot-tfstate-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
