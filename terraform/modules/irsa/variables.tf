variable "project" {
  description = "Project name prefix."
  type        = string
}

variable "environment" {
  description = "Environment name."
  type        = string
}

variable "aws_region" {
  description = "AWS region, used in Secrets Manager ARN construction."
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID, used in Secrets Manager ARN construction."
  type        = string
}

variable "oidc_provider_arn" {
  description = "IAM OIDC provider ARN from the eks module. Used as the Federated principal in trust policies."
  type        = string
}

variable "oidc_provider_url" {
  description = "OIDC issuer URL (no https:// prefix) from the eks module. Used in trust policy Condition keys."
  type        = string
}

variable "s3_media_bucket_arn" {
  description = <<-EOT
    S3 media bucket ARN, built from var.s3_media_bucket_name in root main.tf
    rather than passed as module.s3.bucket_arn — see root main.tf comment
    for why (avoids circular module dependency with the s3 module).
  EOT
  type        = string
}

variable "backend_namespace" {
  description = "Kubernetes namespace the backend Deployment runs in. Must match Helm chart's namespace exactly."
  type        = string
  default     = "penwave"
}

variable "backend_sa_name" {
  description = "ServiceAccount name the backend pods use. Must match Helm chart's serviceAccountName exactly."
  type        = string
  default     = "penwave-backend"
}

variable "external_secrets_namespace" {
  description = "Namespace the External Secrets Operator is installed into."
  type        = string
  default     = "external-secrets"
}

variable "alb_controller_namespace" {
  description = "Namespace the AWS Load Balancer Controller is installed into."
  type        = string
  default     = "kube-system"
}

variable "alb_controller_sa_name" {
  description = <<-EOT
    ServiceAccount name the ALB Controller Helm chart creates. Must match
    exactly — the chart defaults to "aws-load-balancer-controller" unless
    overridden via serviceAccount.name in Helm values.
  EOT
  type        = string
  default     = "aws-load-balancer-controller"
}

variable "argocd_namespace" {
  description = "Namespace ArgoCD is installed into. Accepted for future IRSA wiring (e.g. ArgoCD Notifications to SNS); unused by any role today."
  type        = string
  default     = "argocd"
}

# ── Secrets to write into AWS Secrets Manager ─────────────────────────────────
variable "jwt_access_secret" {
  type      = string
  sensitive = true
}

variable "jwt_refresh_secret" {
  type      = string
  sensitive = true
}

variable "cookie_secret" {
  type      = string
  sensitive = true
}

variable "metrics_secret" {
  type      = string
  sensitive = true
}

variable "grafana_password" {
  type      = string
  sensitive = true
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "redis_auth_token" {
  type      = string
  sensitive = true
}
