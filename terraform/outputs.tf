output "s3_bucket_name" {
  description = "S3 bucket used for Mimir object storage."
  value       = aws_s3_bucket.mimir.id
}

output "kms_key_arn" {
  description = "ARN of the CMK encrypting the Mimir bucket."
  value       = aws_kms_key.mimir.arn
}

output "mimir_component_role_arns" {
  description = "IAM role ARNs mapped by component."
  value       = { for name, role in aws_iam_role.mimir : name => role.arn }
}

output "replication_role_arn" {
  description = "IAM role ARN used for S3 bucket replication (if enabled)."
  value       = try(aws_iam_role.replication[0].arn, null)
}
