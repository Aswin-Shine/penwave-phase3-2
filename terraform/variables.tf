# ─────────────────────────────────────────────────────────────────────────────
# Root Variables
# All values flow from environments/prod/terraform.tfvars
# Sensitive values come from environment variables: TF_VAR_<name>
# ─────────────────────────────────────────────────────────────────────────────

# ── Project ───────────────────────────────────────────────────────────────────
variable "project" {
  description = "Project name. Used as prefix for all resource names."
  type        = string
  default     = "penwave"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,15}$", var.project))
    error_message = "project must be 3-16 lowercase alphanumeric chars or hyphens, starting with a letter."
  }
}

variable "environment" {
  description = "Deployment environment. Controls cost-saving flags (multi_az, backups, etc.)."
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging, or prod."
  }
}

variable "aws_region" {
  description = "AWS region. Must match the region in your AWS CLI profile."
  type        = string
  default     = "us-east-1"
}

variable "domain_name" {
  description = "Primary domain name. Used in CORS headers and S3 bucket policy."
  type        = string
  default     = "penwave.ddns.net"
}

# ── Networking ────────────────────────────────────────────────────────────────
variable "vpc_cidr" {
  description = "CIDR for the VPC. /16 gives 65,534 addresses — sufficient for EKS node + pod scaling."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = <<-EOT
    CIDR blocks for public subnets (one per AZ).
    EKS ALB controller places load balancers here.
    Minimum 2 AZs required for ALB.
  EOT
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = <<-EOT
    CIDR blocks for private subnets (one per AZ).
    EKS nodes, RDS, and ElastiCache live here.
    Egress via NAT Gateway — no direct internet exposure.
  EOT
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}

# ── EKS ───────────────────────────────────────────────────────────────────────
variable "cluster_version" {
  description = <<-EOT
    EKS Kubernetes version.
    EKS supports N-2 minor versions. Check:
    https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html
  EOT
  type        = string
  default     = "1.31"
}

variable "node_instance_types" {
  description = <<-EOT
    EC2 instance types for EKS Auto Mode node pools.
    t3.medium: 2 vCPU / 4GB RAM — minimum for running frontend + backend + system pods.
    t3.small (2vCPU/2GB) is too small; system daemonsets alone consume ~800MB.
  EOT
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_capacity_type" {
  description = <<-EOT
    ON_DEMAND or SPOT.
    SPOT: ~70% cheaper but can be interrupted. Fine for dev/learning.
    ON_DEMAND: stable, use for prod workloads.
  EOT
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.node_capacity_type)
    error_message = "node_capacity_type must be ON_DEMAND or SPOT."
  }
}

# ── RDS ───────────────────────────────────────────────────────────────────────
variable "db_instance_class" {
  description = "RDS instance class. db.t3.micro = free tier eligible."
  type        = string
  default     = "db.t3.micro"
}

variable "db_name" {
  description = "PostgreSQL database name."
  type        = string
  default     = "penwave"
}

variable "db_username" {
  description = "PostgreSQL master username."
  type        = string
  default     = "penwave"
}

variable "db_password" {
  description = "PostgreSQL master password. Set via TF_VAR_db_password env var."
  type        = string
  sensitive   = true
}

variable "db_allocated_storage" {
  description = "RDS initial storage in GB."
  type        = number
  default     = 20
}

# ── ElastiCache ───────────────────────────────────────────────────────────────
variable "redis_node_type" {
  description = "ElastiCache node type."
  type        = string
  default     = "cache.t3.micro"
}

variable "redis_auth_token" {
  description = <<-EOT
    Redis AUTH token (16-128 chars).
    Required when transit_encryption_enabled = true.
    Set via TF_VAR_redis_auth_token env var.
    Generate: openssl rand -hex 32
  EOT
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.redis_auth_token) >= 16 && length(var.redis_auth_token) <= 128
    error_message = "redis_auth_token must be 16-128 characters."
  }
}

# ── S3 ────────────────────────────────────────────────────────────────────────
variable "s3_media_bucket_name" {
  description = "S3 bucket name for media uploads. Must be globally unique."
  type        = string
  default     = "penwave-media-prod"
}

# ── Application Secrets ───────────────────────────────────────────────────────
# These are written to AWS Secrets Manager by Terraform.
# External Secrets Operator reads them into Kubernetes Secrets at deploy time.
# Pods never see raw values — only the SecretStore reference.
variable "jwt_access_secret" {
  description = "JWT access token signing secret. Min 32 chars. Set via TF_VAR_jwt_access_secret."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.jwt_access_secret) >= 32
    error_message = "jwt_access_secret must be at least 32 characters."
  }
}

variable "jwt_refresh_secret" {
  description = "JWT refresh token signing secret. Min 32 chars. Set via TF_VAR_jwt_refresh_secret."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.jwt_refresh_secret) >= 32
    error_message = "jwt_refresh_secret must be at least 32 characters."
  }
}

variable "cookie_secret" {
  description = "Cookie signing secret. Set via TF_VAR_cookie_secret."
  type        = string
  sensitive   = true
}

variable "metrics_secret" {
  description = "Bearer token for /metrics endpoint. Min 16 chars. Set via TF_VAR_metrics_secret."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.metrics_secret) >= 16
    error_message = "metrics_secret must be at least 16 characters."
  }
}

variable "grafana_password" {
  description = "Grafana admin password. Set via TF_VAR_grafana_password."
  type        = string
  sensitive   = true
}

variable "dockerhub_username" {
  description = "Docker Hub username for pulling private images."
  type        = string
}
