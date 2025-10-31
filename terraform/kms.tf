data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "kms" {
  statement {
    sid    = "AllowRootAccount"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }

  statement {
    sid    = "AllowS3UseOfTheKey"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }

    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:aws:s3:arn"
      values   = ["${local.bucket_arn}/*"]
    }
  }

  dynamic "statement" {
    for_each = var.kms_allowed_principals
    content {
      effect = "Allow"

      principals {
        type        = "AWS"
        identifiers = [statement.value]
      }

      actions = [
        "kms:Decrypt",
        "kms:DescribeKey",
        "kms:GenerateDataKey",
        "kms:GenerateDataKeyWithoutPlaintext",
      ]

      resources = ["*"]
    }
  }
}

resource "aws_kms_key" "mimir" {
  description             = "CMK for Mimir object storage encryption at rest."
  deletion_window_in_days = 30
  enable_key_rotation     = true
  multi_region            = true
  policy                  = data.aws_iam_policy_document.kms.json

  tags = merge(
    {
      "Name"        = "mimir-sse"
      "Environment" = var.environment
      "ManagedBy"   = "IaC"
      "Stack"       = "monitoring"
    },
    var.tags,
  )
}

resource "aws_kms_alias" "mimir" {
  name          = var.kms_key_alias
  target_key_id = aws_kms_key.mimir.id
}
