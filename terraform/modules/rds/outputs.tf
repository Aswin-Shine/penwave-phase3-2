output "endpoint" {
  description = "RDS instance endpoint (host:port)."
  value       = aws_db_instance.postgres.endpoint
  sensitive   = true
}

output "address" {
  description = "RDS instance address (host only, no port)."
  value       = aws_db_instance.postgres.address
  sensitive   = true
}

output "db_name" {
  description = "Database name."
  value       = aws_db_instance.postgres.db_name
}

output "instance_id" {
  description = "RDS instance identifier."
  value       = aws_db_instance.postgres.id
}
