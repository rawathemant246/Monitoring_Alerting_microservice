locals {
  bucket_objects_arn  = "${local.bucket_arn}/*"
  oidc_provider_path  = trimprefix(var.eks_oidc_provider_url, "https://")
}

data "aws_iam_policy_document" "assume_role" {
  for_each = var.mimir_service_accounts

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    condition {
      test     = "StringEquals"
      variable = "${locals.oidc_provider_path}:sub"
      values   = ["system:serviceaccount:${each.value.namespace}:${each.key}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${locals.oidc_provider_path}:aud"
      values   = ["sts.amazonaws.com"]
    }

    principals {
      type        = "Federated"
      identifiers = [var.eks_oidc_provider_arn]
    }
  }
}

resource "aws_iam_role" "mimir" {
  for_each = var.mimir_service_accounts

  name               = "${var.environment}-mimir-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.assume_role[each.key].json

  tags = merge(
    {
      "Environment" = var.environment
      "ManagedBy"   = "IaC"
      "Stack"       = "monitoring"
      "Component"   = each.key
    },
    var.tags,
  )
}

data "aws_iam_policy_document" "s3_readwrite" {
  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [local.bucket_arn]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:GetObjectTagging",
      "s3:PutObjectTagging",
    ]
    resources = [local.bucket_objects_arn]
  }

  statement {
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:Encrypt",
      "kms:GenerateDataKey",
      "kms:GenerateDataKeyWithoutPlaintext",
      "kms:ReEncrypt*",
    ]
    resources = [aws_kms_key.mimir.arn]
  }
}

data "aws_iam_policy_document" "s3_readonly" {
  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [local.bucket_arn]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectTagging",
    ]
    resources = [local.bucket_objects_arn]
  }

  statement {
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:GenerateDataKey",
      "kms:GenerateDataKeyWithoutPlaintext",
    ]
    resources = [aws_kms_key.mimir.arn]
  }
}

resource "aws_iam_role_policy" "mimir" {
  for_each = aws_iam_role.mimir

  name   = "${each.key}-s3-access"
  role   = each.value.id
  policy = var.mimir_service_accounts[each.key].access == "readwrite" ? data.aws_iam_policy_document.s3_readwrite.json : data.aws_iam_policy_document.s3_readonly.json
}
