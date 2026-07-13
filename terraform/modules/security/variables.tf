variable "project" {
  description = "Project name prefix."
  type        = string
}

variable "environment" {
  description = "Environment name."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID to create security groups in."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block, reserved for future use (e.g. broader internal rules)."
  type        = string
}
