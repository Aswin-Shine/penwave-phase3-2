variable "project" {
  description = "Project name prefix."
  type        = string
}

variable "environment" {
  description = "Environment name."
  type        = string
}

variable "cache_subnet_group_name" {
  description = "ElastiCache subnet group name, from the vpc module."
  type        = string
}

variable "security_group_ids" {
  description = "Security group IDs to attach to the Redis replication group."
  type        = list(string)
}

variable "redis_node_type" {
  description = "ElastiCache node type."
  type        = string
}

variable "redis_auth_token" {
  description = "Redis AUTH token. Must be 16-128 chars."
  type        = string
  sensitive   = true
}
