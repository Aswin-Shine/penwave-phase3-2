output "primary_endpoint_address" {
  description = "Redis primary endpoint address."
  value       = aws_elasticache_replication_group.redis.primary_endpoint_address
  sensitive   = true
}

output "port" {
  description = "Redis port."
  value       = aws_elasticache_replication_group.redis.port
}
