output "eks_cluster_sg_id" {
  description = "EKS control plane additional security group ID."
  value       = aws_security_group.eks_cluster.id
}

output "eks_node_sg_id" {
  description = "EKS worker node security group ID."
  value       = aws_security_group.eks_nodes.id
}

output "rds_sg_id" {
  description = "RDS security group ID."
  value       = aws_security_group.rds.id
}

output "redis_sg_id" {
  description = "ElastiCache Redis security group ID."
  value       = aws_security_group.elasticache.id
}
