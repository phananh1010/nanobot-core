terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Remote state in S3 — create the bucket once before running `terraform init`:
  #   aws s3 mb s3://nanobot-tfstate-<YOUR_ACCOUNT_ID> --region <YOUR_REGION>
  #   aws dynamodb create-table \
  #     --table-name nanobot-tfstate-lock \
  #     --attribute-definitions AttributeName=LockID,AttributeType=S \
  #     --key-schema AttributeName=LockID,KeyType=HASH \
  #     --billing-mode PAY_PER_REQUEST \
  #     --region <YOUR_REGION>
  #
  # Then uncomment this block and fill in bucket/region:
  #
  # backend "s3" {
  #   bucket         = "nanobot-tfstate-<YOUR_ACCOUNT_ID>"
  #   key            = "nanobot/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "nanobot-tfstate-lock"
  #   encrypt        = true
  # }
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
