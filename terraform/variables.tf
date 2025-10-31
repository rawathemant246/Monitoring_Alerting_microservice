variable "aws_region" {
  type        = string
  description = "AWS region for all resources."
}

variable "environment" {
  type        = string
  description = "Deployment environment tag (e.g., prod, staging)."
  default     = "prod"
}

variable "s3_bucket_name" {
  type        = string
  description = "Name of the S3 bucket used for Mimir object storage."
}

variable "kms_key_alias" {
  type        = string
  description = "Alias assigned to the KMS key for SSE. Must start with alias/."
  default     = "alias/mimir-sse"
}

variable "eks_oidc_provider_arn" {
  type        = string
  description = "OIDC provider ARN for the EKS cluster (for IRSA)."
}

variable "eks_oidc_provider_url" {
  type        = string
  description = "OIDC provider URL for the EKS cluster (for IRSA)."
}

variable "mimir_service_accounts" {
  description = "Map of Mimir components to namespaces and access level."
  type = map(object({
    namespace = string
    access    = string
  }))
  default = {
    distributor    = { namespace = "monitoring", access = "readwrite" }
    ingester       = { namespace = "monitoring", access = "readwrite" }
    compactor      = { namespace = "monitoring", access = "readwrite" }
    store-gateway  = { namespace = "monitoring", access = "readonly" }
    querier        = { namespace = "monitoring", access = "readonly" }
    query-frontend = { namespace = "monitoring", access = "readonly" }
    ruler          = { namespace = "monitoring", access = "readonly" }
  }

  validation {
    condition = alltrue([
      for sa in values(var.mimir_service_accounts) : contains(["readwrite", "readonly"], sa.access)
    ])
    error_message = "Access must be one of readwrite or readonly."
  }
}

variable "kms_allowed_principals" {
  description = "Additional IAM principals allowed to use the CMK."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Additional tags to attach to resources."
  type        = map(string)
  default     = {}
}
