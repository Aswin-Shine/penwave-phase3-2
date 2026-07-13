output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "VPC CIDR block."
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet IDs, for ALB placement."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs, for EKS nodes, RDS, and ElastiCache."
  value       = aws_subnet.private[*].id
}

output "db_subnet_group_name" {
  description = "RDS subnet group name."
  value       = aws_db_subnet_group.main.name
}

output "cache_subnet_group_name" {
  description = "ElastiCache subnet group name."
  value       = aws_elasticache_subnet_group.main.name
}

output "nat_gateway_ip" {
  description = "NAT Gateway public IP. Use this to allowlist egress IP in third-party APIs if needed."
  value       = aws_eip.nat.public_ip
}
