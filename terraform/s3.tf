terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

locals {
  bucket_arn = "arn:aws:s3:::${var.s3_bucket_name}"
}

resource "aws_s3_bucket" "mimir" {
  bucket = var.s3_bucket_name

  force_destroy = false

  tags = merge(
    {
      "Name"        = "mimir-object-storage"
      "Environment" = var.environment
      "ManagedBy"   = "IaC"
      "Stack"       = "monitoring"
    },
    var.tags,
  )
}

resource "aws_s3_bucket_versioning" "mimir" {
  bucket = aws_s3_bucket.mimir.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "mimir" {
  bucket = aws_s3_bucket.mimir.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.mimir.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "mimir" {
  bucket = aws_s3_bucket.mimir.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "mimir" {
  bucket = aws_s3_bucket.mimir.id

  rule {
    id     = "mimir-tiered-storage"
    status = "Enabled"

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = 365
    }
  }
}
