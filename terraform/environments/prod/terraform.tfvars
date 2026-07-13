# ─────────────────────────────────────────────────────────────────────────────
# Production Environment Variables
#
# This file is SAFE TO COMMIT — it contains no secrets.
# All sensitive values (passwords, tokens, JWT secrets) are intentionally
# absent here. Set them via environment variables before running terraform:
#
#   export TF_VAR_db_password="..."
#   export TF_VAR_redis_auth_token="$(openssl rand -hex 32)"
#   export TF_VAR_jwt_access_secret="$(openssl rand -hex 32)"
#   export TF_VAR_jwt_refresh_secret="$(openssl rand -hex 32)"
#   export TF_VAR_cookie_secret="$(openssl rand -hex 32)"
#   export TF_VAR_metrics_secret="$(openssl rand -hex 16)"
#   export TF_VAR_grafana_password="..."
#
# This is the fix for the Phase 2 incident where prod.tfvars was committed
# to git with real credentials inside it. Splitting sensitive vs
# non-sensitive into separate delivery mechanisms makes that class of
# mistake structurally harder to repeat — there's no file containing
# secrets to accidentally `git add`.
# ─────────────────────────────────────────────────────────────────────────────

project     = "penwave"
environment = "prod"
aws_region  = "us-east-1"
domain_name = "penwave.ddns.net"

# ── Networking ────────────────────────────────────────────────────────────────
vpc_cidr              = "10.0.0.0/16"
public_subnet_cidrs   = ["10.0.1.0/24", "10.0.2.0/24"]
private_subnet_cidrs  = ["10.0.11.0/24", "10.0.12.0/24"]

# ── EKS ───────────────────────────────────────────────────────────────────────
cluster_version      = "1.31"
node_instance_types  = ["t3.medium"]
node_capacity_type    = "ON_DEMAND" # switch to SPOT if you want to practice interruption handling

# ── RDS ───────────────────────────────────────────────────────────────────────
db_instance_class    = "db.t3.micro"
db_name               = "penwave"
db_username           = "penwave"
db_allocated_storage  = 20

# ── ElastiCache ───────────────────────────────────────────────────────────────
redis_node_type = "cache.t3.micro"

# ── S3 ────────────────────────────────────────────────────────────────────────
# Must be globally unique across ALL AWS accounts, not just yours.
# Append your AWS account ID or a random suffix if this is taken.
s3_media_bucket_name = "penwave-media-prod-aswin"

# ── Misc ──────────────────────────────────────────────────────────────────────
dockerhub_username = "your-dockerhub-username"
