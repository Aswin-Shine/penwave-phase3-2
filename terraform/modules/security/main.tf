# ─────────────────────────────────────────────────────────────────────────────
# Security Module
# Least-privilege security groups for EKS cluster, EKS nodes, RDS, and Redis.
#
# Design: EKS Auto Mode manages most node-level security automatically, but
# we still need explicit SGs for RDS and Redis to restrict access to only
# the EKS node security group — not the whole VPC CIDR.
# ─────────────────────────────────────────────────────────────────────────────

# ── EKS Cluster Security Group ────────────────────────────────────────────────
# Controls traffic to/from the EKS control plane (API server).
# EKS automatically adds rules for node-to-control-plane communication;
# this SG is the "additional" SG attached to the control plane ENIs.
resource "aws_security_group" "eks_cluster" {
  name        = "${var.project}-eks-cluster-sg-${var.environment}"
  description = "EKS control plane additional security group"
  vpc_id      = var.vpc_id

  egress {
    description = "All outbound control plane needs to reach nodes, AWS APIs"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-eks-cluster-sg-${var.environment}" }
}

# ── EKS Node Security Group ───────────────────────────────────────────────────
# Attached to all worker nodes (Auto Mode provisions nodes with this SG).
# Allows: control plane → node (kubelet API), node → node (pod-to-pod CNI),
# and all egress (image pulls, AWS API calls, NAT-routed internet).
resource "aws_security_group" "eks_nodes" {
  name        = "${var.project}-eks-nodes-sg-${var.environment}"
  description = "EKS worker node security group"
  vpc_id      = var.vpc_id

  # Node-to-node: required for CNI (VPC CNI plugin) pod networking
  ingress {
    description = "Node to node all traffic for CNI pod networking"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  # Control plane → node: kubelet API (used for exec, logs, port-forward)
  ingress {
    description     = "Control plane to node kubelet API"
    from_port       = 10250
    to_port         = 10250
    protocol        = "tcp"
    security_groups = [aws_security_group.eks_cluster.id]
  }

  # Control plane → node: webhook/extension API servers (metrics-server, etc.)
  ingress {
    description     = "Control plane to node webhooks"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.eks_cluster.id]
  }

  egress {
    description = "All outbound image pulls, AWS APIs via NAT"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project}-eks-nodes-sg-${var.environment}"
    # Required for EKS Auto Mode to recognize this as a valid node SG
    "kubernetes.io/cluster/${var.project}-eks-${var.environment}" = "owned"
  }
}

# Control plane must also allow inbound from nodes (kubelet → API server: 443)
resource "aws_security_group_rule" "cluster_ingress_from_nodes" {
  description              = "Node to control plane API server"
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.eks_nodes.id
  security_group_id        = aws_security_group.eks_cluster.id
}

# ── RDS Security Group ────────────────────────────────────────────────────────
# Only EKS nodes (and therefore pods, since pods share the node's network
# namespace for egress in default VPC CNI mode) can reach Postgres.
resource "aws_security_group" "rds" {
  name        = "${var.project}-rds-sg-${var.environment}"
  description = "RDS PostgreSQL only reachable from EKS nodes"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from EKS nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.eks_nodes.id]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-rds-sg-${var.environment}" }
}

# ── ElastiCache Security Group ────────────────────────────────────────────────
resource "aws_security_group" "elasticache" {
  name        = "${var.project}-cache-sg-${var.environment}"
  description = "ElastiCache Redis only reachable from EKS nodes"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Redis from EKS nodes"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.eks_nodes.id]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-cache-sg-${var.environment}" }
}
