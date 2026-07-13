# ─────────────────────────────────────────────────────────────────────────────
# EKS Module — Auto Mode, wrapping terraform-aws-modules/eks/aws v20.31
# Wired to existing modules/vpc and modules/security. Does not create its
# own VPC. Does not replace AWS's own auto-created primary cluster SG —
# that SG always exists regardless of what this module does.
# ─────────────────────────────────────────────────────────────────────────────

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  # Auto Mode
  cluster_compute_config = {
    enabled    = true
    node_pools = var.node_pools
  }

  # ── Networking: reuse existing VPC ──────────────────────────────────────────
  vpc_id     = var.vpc_id
  subnet_ids = concat(var.private_subnet_ids, var.public_subnet_ids)

  cluster_endpoint_public_access        = true
  cluster_endpoint_private_access       = true
  cluster_endpoint_public_access_cidrs  = var.cluster_public_access_cidrs

  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true

  cluster_encryption_config = {
    resources = ["secrets"]
  }

  cluster_enabled_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler"
  ]

  # ── Security groups ──────────────────────────────────────────────────────
  # This is ADDITIVE, matching what the old hand-rolled aws_eks_cluster
  # resource did via vpc_config.security_group_ids. AWS always creates its
  # own primary "Cluster security group" regardless of this module — that
  # cannot be replaced or suppressed, only added to. Deliberately NOT using
  # create_cluster_security_group=false / cluster_security_group_id here:
  # that combination has documented unresolved bugs in the module
  # (terraform-aws-modules/terraform-aws-eks#3320 — ambiguous delineation
  # between cluster_security_group_id and cluster_additional_security_group_ids,
  # can force cluster replacement on plan). Using the plain additive input
  # avoids that failure mode entirely.
  cluster_additional_security_group_ids = [var.cluster_security_group_id]

  # NOTE: var.node_security_group_id is intentionally NOT wired into this
  # module. EKS Auto Mode manages its own node security group internally
  # via cluster_compute_config and does not accept a custom one — confirmed
  # by the previous hand-rolled module's own documentation, and consistent
  # with the fact that the actual generated NodeClass in this cluster used
  # AWS's own auto-created SG, not the one modules/security creates. The
  # variable is still declared below for interface parity with root
  # main.tf and modules/security, and is reserved for future use if this
  # cluster ever moves off Auto Mode to eks_managed_node_groups.

  tags = {
    Name = var.cluster_name
  }
}
