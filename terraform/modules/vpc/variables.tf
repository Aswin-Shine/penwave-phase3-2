variable "project" {
  description = "Project name prefix."
  type        = string
}

variable "environment" {
  description = "Environment name (dev/staging/prod)."
  type        = string
}

variable "aws_region" {
  description = "AWS region."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
}

variable "public_subnet_cidrs" {
  description = "List of CIDR blocks for public subnets, one per AZ."
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "List of CIDR blocks for private subnets, one per AZ."
  type        = list(string)
}

variable "eks_cluster_name" {
  description = "EKS cluster name. Used to tag subnets for ALB controller and cluster discovery."
  type        = string
}
