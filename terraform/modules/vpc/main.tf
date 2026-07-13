# ─────────────────────────────────────────────────────────────────────────────
# VPC Module
# Creates a VPC with public + private subnets across 2 AZs, NAT Gateway,
# Internet Gateway, route tables, and subnet groups for RDS/ElastiCache.
#
# Design decision: single NAT Gateway (not one per AZ).
# Rationale: this is a learning project, not a prod system with NAT redundancy
# requirements. One NAT Gateway saves ~$32/month vs two. If the NAT AZ fails,
# private subnet egress breaks but the cluster control plane and existing
# connections are unaffected. Documented as an accepted tradeoff in docs/eks.md.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.project}-vpc-${var.environment}"
    # Required by EKS for VPC resource discovery
    "kubernetes.io/cluster/${var.eks_cluster_name}" = "shared"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project}-igw-${var.environment}" }
}

# ── Public Subnets (one per AZ) ───────────────────────────────────────────────
# ALB controller discovers these via the kubernetes.io/role/elb tag.
resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                                            = "${var.project}-public-${count.index}-${var.environment}"
    "kubernetes.io/cluster/${var.eks_cluster_name}" = "shared"
    "kubernetes.io/role/elb"                        = "1"
  }
}

# ── Private Subnets (one per AZ) ──────────────────────────────────────────────
# EKS nodes, RDS, and ElastiCache live here.
# kubernetes.io/role/internal-elb tag lets ALB controller place internal
# load balancers here if ever needed (e.g. internal admin tooling).
resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name                                            = "${var.project}-private-${count.index}-${var.environment}"
    "kubernetes.io/cluster/${var.eks_cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"               = "1"

    # ─── CRITICAL FOR EKS AUTO MODE NODECLASS VALIDATION ───
    "karpenter.sh/discovery" = var.eks_cluster_name
  }
}

# ── NAT Gateway (single, in first public subnet) ──────────────────────────────
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.project}-nat-eip-${var.environment}" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "${var.project}-nat-${var.environment}" }

  depends_on = [aws_internet_gateway.main]
}

# ── Route Tables ───────────────────────────────────────────────────────────────
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.project}-rt-public-${var.environment}" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = { Name = "${var.project}-rt-private-${var.environment}" }
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ── Subnet Groups for RDS + ElastiCache ───────────────────────────────────────
resource "aws_db_subnet_group" "main" {
  name       = "${var.project}-db-subnet-group-${var.environment}"
  subnet_ids = aws_subnet.private[*].id
  tags       = { Name = "${var.project}-db-subnet-group" }
}

resource "aws_elasticache_subnet_group" "main" {
  name       = "${var.project}-cache-subnet-group-${var.environment}"
  subnet_ids = aws_subnet.private[*].id
  tags       = { Name = "${var.project}-cache-subnet-group" }
}

# ── Data Sources ──────────────────────────────────────────────────────────────
data "aws_availability_zones" "available" {
  state = "available"
}
