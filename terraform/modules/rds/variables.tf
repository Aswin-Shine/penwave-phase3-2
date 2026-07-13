variable "project" {
  description = "Project name prefix."
  type        = string
}

variable "environment" {
  description = "Environment name."
  type        = string
}

variable "db_subnet_group_name" {
  description = "RDS subnet group name, from the vpc module."
  type        = string
}

variable "vpc_security_group_ids" {
  description = "Security group IDs to attach to the RDS instance."
  type        = list(string)
}

variable "db_name" {
  description = "PostgreSQL database name."
  type        = string
}

variable "db_username" {
  description = "PostgreSQL master username."
  type        = string
}

variable "db_password" {
  description = "PostgreSQL master password."
  type        = string
  sensitive   = true
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
}

variable "db_allocated_storage" {
  description = "Initial allocated storage in GB."
  type        = number
}

variable "multi_az" {
  description = "Enable Multi-AZ failover. Default false to save cost/time for short-lived clusters."
  type        = bool
  default     = false
}
