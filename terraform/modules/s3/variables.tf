variable "project" {
  description = "Project name prefix."
  type        = string
}

variable "environment" {
  description = "Environment name."
  type        = string
}

variable "domain_name" {
  description = "Domain name, used in CORS allowed_origins."
  type        = string
}

variable "s3_media_bucket_name" {
  description = "S3 bucket name. Must be globally unique across all AWS accounts."
  type        = string
}

variable "backend_irsa_role_arn" {
  description = <<-EOT
    ARN of the backend's IRSA role (from the irsa module).
    Used in the bucket policy Principal to grant access.

    NOTE ON DEPENDENCY ORDERING: this creates main.tf -> irsa module ->
    s3 module call order. The irsa module's own S3 policy references the
    bucket ARN as a known string pattern (arn:aws:s3:::bucket-name/*)
    built from the bucket NAME variable, not a resource output — this
    breaks what would otherwise be a circular dependency between the
    s3 and irsa modules. See modules/irsa/main.tf for the matching side.
  EOT
  type        = string
}
