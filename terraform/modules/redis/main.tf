# ─────────────────────────────────────────────────────────────────────────────
# Redis Module (ElastiCache)
# Carried forward from Phase 2 with the same fix: aws_elasticache_cluster
# does not reliably support auth_token + TLS together across provider
# versions, so we use aws_elasticache_replication_group even for a
# single-node deployment.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id = "${var.project}-redis-${var.environment}"
  description           = "Penwave Redis cache - ${var.environment}"

  engine             = "redis"
  engine_version     = "7.1"
  node_type          = var.redis_node_type
  num_cache_clusters = 1
  port               = 6379

  subnet_group_name = var.cache_subnet_group_name
  security_group_ids = var.security_group_ids

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                  = var.redis_auth_token

  maintenance_window        = "sun:05:00-sun:06:00"
  snapshot_retention_limit  = 0 # short-lived cluster, no need to retain snapshots
  apply_immediately          = true

  tags = { Name = "${var.project}-redis-${var.environment}" }
}
