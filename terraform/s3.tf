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
  bucket_arn                    = "arn:aws:s3:::${var.s3_bucket_name}"
  replication_enabled           = var.enable_replication
  replication_destination_arn   = var.replication_destination_bucket_arn
  replication_destination_region = var.replication_destination_bucket_region
  replication_destination_kms   = var.replication_destination_kms_key_id
  replication_destination_account = var.replication_destination_account_id
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

data "aws_iam_policy_document" "replication_assume" {
  count = local.replication_enabled ? 1 : 0

  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

data "aws_iam_policy_document" "replication_policy" {
  count = local.replication_enabled ? 1 : 0

  statement {
    effect = "Allow"
    actions = [
      "s3:GetReplicationConfiguration",
      "s3:ListBucket",
    ]
    resources = [local.bucket_arn]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:GetObjectVersionForReplication",
      "s3:GetObjectVersionAcl",
      "s3:GetObjectVersionTagging",
      "s3:ReplicateObject",
      "s3:ReplicateDelete",
      "s3:ReplicateTags",
      "s3:ObjectOwnerOverrideToBucketOwner"
    ]
    resources = ["${local.bucket_arn}/*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:Encrypt",
      "kms:GenerateDataKey*",
      "kms:DescribeKey"
    ]
    resources = [aws_kms_key.mimir.arn]
  }
}

resource "aws_iam_role" "replication" {
  count = local.replication_enabled ? 1 : 0

  name               = "${var.environment}-mimir-replication"
  assume_role_policy = data.aws_iam_policy_document.replication_assume[0].json

  tags = merge(
    {
      "Environment" = var.environment
      "ManagedBy"   = "IaC"
      "Stack"       = "monitoring"
      "Component"   = "replication"
    },
    var.tags,
  )
}

resource "aws_iam_role_policy" "replication" {
  count = local.replication_enabled ? 1 : 0

  name   = "mimir-replication-policy"
  role   = aws_iam_role.replication[0].id
  policy = data.aws_iam_policy_document.replication_policy[0].json
}

resource "aws_s3_bucket_replication_configuration" "mimir" {
  count = local.replication_enabled ? 1 : 0

  depends_on = [aws_s3_bucket_versioning.mimir]

  bucket = aws_s3_bucket.mimir.id
  role   = aws_iam_role.replication[0].arn

  lifecycle {
    precondition {
      condition     = local.replication_destination_arn != ""
      error_message = "replication_destination_bucket_arn must be set when enable_replication is true."
    }
    precondition {
      condition     = local.replication_destination_region != ""
      error_message = "replication_destination_bucket_region must be set when enable_replication is true."
    }
  }

  rule {
    id     = "cross-region-dr"
    status = "Enabled"

    delete_marker_replication {
      status = "Enabled"
    }

    filter {
      prefix = ""
    }

    destination {
      bucket        = local.replication_destination_arn
      storage_class = "STANDARD"
      region        = local.replication_destination_region
      replica_kms_key_id = local.replication_destination_kms != "" ? local.replication_destination_kms : aws_kms_key.mimir.arn
      account        = local.replication_destination_account != "" ? local.replication_destination_account : null
      metrics {
        status = "Enabled"
      }
      dynamic "access_control_translation" {
        for_each = local.replication_destination_account != "" ? [1] : []
        content {
          owner = "Destination"
        }
      }
    }

    source_selection_criteria {
      sse_kms_encrypted_objects {
        enabled = true
      }
    }
  }

  timeouts {
    create = "15m"
    update = "15m"
  }
}
