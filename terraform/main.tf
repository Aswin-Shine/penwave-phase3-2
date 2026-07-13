# ─────────────────────────────────────────────────────────────────────────────
# Penwave Phase 3 — Root Terraform Configuration
# Orchestrates all infrastructure modules for EKS-based deployment.
#
# Module dependency order (Terraform resolves automatically via references,
# this comment documents the ACTUAL graph, not file position):
#   vpc → security → rds/redis → eks → irsa → s3
#   (s3 depends on irsa.backend_role_arn; irsa depends on eks's OIDC outputs;
#   despite module "s3" appearing before module "irsa" in this file, file
#   order does not determine apply order — only references do.)
#
# Apply order on fresh account:
#   terraform init
#   terraform plan -var-file=environments/prod/terraform.tfvars -out=tfplan
#   terraform apply tfplan
# ─────────────────────────────────────────────────────────────────────────────

# ── VPC & Networking ──────────────────────────────────────────────────────────
# Creates VPC, public/private subnets across 2 AZs, IGW, NAT Gateway,
# route tables, and subnet groups for RDS + ElastiCache.
module "vpc" {
  source = "./modules/vpc"

  project     = var.project
  environment = var.environment
  aws_region  = var.aws_region

  vpc_cidr             = var.vpc_cidr
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs

  # EKS requires these tags on subnets for ALB controller auto-discovery
  eks_cluster_name = local.cluster_name
}

# ── Security Groups ──────────────────────────────────────────────────────────
# Least-privilege SGs for each tier. EKS nodes get their own SG
# managed by the eks module, but RDS/Redis SGs reference the node SG.
module "security" {
  source = "./modules/security"

  project     = var.project
  environment = var.environment
  vpc_id      = module.vpc.vpc_id
  vpc_cidr    = var.vpc_cidr
}

# ── RDS PostgreSQL ────────────────────────────────────────────────────────────
# Preserves existing Phase 2 database. No data migration needed —
# EKS pods connect to the same RDS endpoint via the private subnet.
module "rds" {
  source = "./modules/rds"

  project     = var.project
  environment = var.environment

  db_subnet_group_name   = module.vpc.db_subnet_group_name
  vpc_security_group_ids = [module.security.rds_sg_id]

  db_name              = var.db_name
  db_username          = var.db_username
  db_password          = var.db_password
  db_instance_class    = var.db_instance_class
  db_allocated_storage = var.db_allocated_storage
}

# ── ElastiCache Redis ─────────────────────────────────────────────────────────
# Single-node Redis for cost optimisation. Auth token + TLS preserved
# from Phase 2. EKS pods connect via rediss:// URL.
module "redis" {
  source = "./modules/redis"

  project     = var.project
  environment = var.environment

  cache_subnet_group_name = module.vpc.cache_subnet_group_name
  security_group_ids      = [module.security.redis_sg_id]

  redis_node_type  = var.redis_node_type
  redis_auth_token = var.redis_auth_token
}

# ── S3 ────────────────────────────────────────────────────────────────────────
# Media bucket for user uploads. IRSA gives backend pods scoped access.
# No IAM user / static credentials needed.
module "s3" {
  source = "./modules/s3"

  project     = var.project
  environment = var.environment
  domain_name = var.domain_name

  s3_media_bucket_name = var.s3_media_bucket_name

  # Backend pod IRSA role ARN — created after eks module, wired via depends_on
  backend_irsa_role_arn = module.irsa.backend_role_arn
}

# ── EKS Cluster (Auto Mode) ───────────────────────────────────────────────────
# EKS Auto Mode: AWS manages node lifecycle, patching, and scaling.
# No managed node groups or self-managed nodes to configure.
# Control plane + OIDC provider created here; node pools are Auto Mode.
module "eks" {
  source = "./modules/eks"

  project     = var.project
  environment = var.environment
  aws_region  = var.aws_region

  cluster_name    = local.cluster_name
  cluster_version = var.cluster_version

  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  public_subnet_ids  = module.vpc.public_subnet_ids

  cluster_security_group_id = module.security.eks_cluster_sg_id
  node_security_group_id    = module.security.eks_node_sg_id

  # Auto Mode node pool config
  node_instance_types = var.node_instance_types
  node_capacity_type  = var.node_capacity_type

  # IAM: cluster role, node role, and OIDC provider
  aws_account_id = data.aws_caller_identity.current.account_id
}

# ── RDS/Redis ingress fix: Auto Mode primary cluster SG ─────────────────────
# modules/security's RDS and Redis SGs (aws_security_group.rds,
# aws_security_group.elasticache) both allow ingress from
# module.security.eks_nodes_sg only. Confirmed via live NodeClass inspection
# this session that EKS Auto Mode attaches nodes to AWS's own auto-generated
# primary cluster security group instead — the eks_nodes SG from
# modules/security has nothing attached to it and was never a valid
# ingress source under Auto Mode. These two rules are additive: they don't
# replace the existing eks_nodes-based rules (harmless to leave those in
# place), they just add the SG that real traffic actually originates from.
#
# Placed here, not in modules/security, because modules/security applies
# before modules/eks in the dependency graph and has no way to reference
# a security group ID that doesn't exist until the cluster is created.
resource "aws_security_group_rule" "rds_from_eks_primary_sg" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = module.security.rds_sg_id
  source_security_group_id = module.eks.cluster_primary_security_group_id
  description              = "PostgreSQL from EKS Auto Mode nodes"
}

resource "aws_security_group_rule" "redis_from_eks_primary_sg" {
  type                     = "ingress"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  security_group_id        = module.security.redis_sg_id
  source_security_group_id = module.eks.cluster_primary_security_group_id
  description              = "Redis from EKS Auto Mode nodes"
}

# ── IRSA — IAM Roles for Service Accounts ────────────────────────────────────
# This is the correct way for pods to call AWS APIs.
# Each ServiceAccount gets a scoped IAM role via OIDC federation.
# Zero static credentials. Tokens auto-rotate every hour.
#
# What happens at runtime:
#   1. EKS injects a projected ServiceAccount token into the pod
#   2. AWS SDK calls STS AssumeRoleWithWebIdentity with that token
#   3. STS validates token against cluster OIDC issuer
#   4. STS returns temporary credentials scoped to this role only
#   5. Role trust policy ensures ONLY this SA in this namespace can assume it
module "irsa" {
  source = "./modules/irsa"

  project     = var.project
  environment = var.environment

  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url

  # IMPORTANT: built from the bucket NAME variable, not module.s3.bucket_arn.
  # module.s3's bucket policy references module.irsa.backend_role_arn, so
  # the reverse reference (irsa -> s3 output) would create a circular
  # module dependency that Terraform refuses to graph. Both modules derive
  # the same ARN independently from var.s3_media_bucket_name instead.
  s3_media_bucket_arn = "arn:aws:s3:::${var.s3_media_bucket_name}"
  aws_account_id      = data.aws_caller_identity.current.account_id

  # Namespace + ServiceAccount names must match what Helm deploys
  backend_namespace          = "penwave"
  backend_sa_name            = "penwave-backend"
  argocd_namespace           = "argocd"
  external_secrets_namespace = "external-secrets"

  # ALB Controller — confirmed against the actual ServiceAccount created by
  # `helm install aws-load-balancer-controller` (kubectl get sa output,
  # 2026-07-03): namespace kube-system, name aws-load-balancer-controller.
  # These match modules/irsa's own defaults, but set explicitly here rather
  # than relying on the default — same convention already used for
  # backend_namespace/backend_sa_name above, so a future default change in
  # the module can't silently drift this trust policy with no visible
  # change in root main.tf.
  alb_controller_namespace = "kube-system"
  alb_controller_sa_name   = "aws-load-balancer-controller"

  aws_region = var.aws_region

  # Written into AWS Secrets Manager; ESO syncs these into K8s Secrets
  jwt_access_secret  = var.jwt_access_secret
  jwt_refresh_secret = var.jwt_refresh_secret
  cookie_secret      = var.cookie_secret
  metrics_secret     = var.metrics_secret
  grafana_password   = var.grafana_password
  db_password        = var.db_password
  redis_auth_token   = var.redis_auth_token
}

# ── Locals ────────────────────────────────────────────────────────────────────
locals {
  cluster_name = "${var.project}-eks-${var.environment}"
}

# ── Data Sources ──────────────────────────────────────────────────────────────
data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" { state = "available" }
