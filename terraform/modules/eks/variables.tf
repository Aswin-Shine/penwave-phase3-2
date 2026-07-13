variable "project" {
  description = "Project name prefix. Not currently consumed inside this module — accepted for interface parity with every other module (security, rds, redis) which all take it. Left unused rather than dropped so root main.tf doesn't need a special case for this one module."
  type        = string
}

variable "environment" {
  description = "Environment name. See project variable note above — unused here, accepted for interface parity."
  type        = string
}

variable "aws_region" {
  description = "AWS region. Unused here — accepted for interface parity with other modules."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS control plane."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for node placement."
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Public subnet IDs. Included in cluster subnet_ids so the ALB controller can place internet facing load balancers."
  type        = list(string)
}

variable "cluster_security_group_id" {
  description = "Additional security group ID for the cluster control plane ENIs. Additive only — AWS's own primary cluster SG is unaffected."
  type        = string
}

variable "node_security_group_id" {
  description = <<-EOT
    Node security group ID. NOT wired into this module — EKS Auto Mode
    manages its own node security group internally and does not accept a
    custom one via cluster_compute_config. Accepted here only for interface
    consistency with the security module and root main.tf, and reserved for
    future use if you switch from Auto Mode to eks_managed_node_groups.
  EOT
  type = string
}

variable "node_instance_types" {
  description = <<-EOT
    NOT wired into this module. EKS Auto Mode's built-in node pool presets
    (general-purpose, system) select instance types themselves via internal
    requirements (category/generation constraints), not an explicit type
    list. Accepted here so root main.tf and terraform.tfvars don't need
    changes; the t3.medium value currently set has no effect on what Auto
    Mode actually provisions. If you need to guarantee a minimum instance
    size, that has to be done via a custom NodePool's requirements block in
    Kubernetes, not here.
  EOT
  type = list(string)
}

variable "node_capacity_type" {
  description = "NOT wired into this module, same reason as node_instance_types — Auto Mode's built-in presets don't take this. Accepted for interface parity only."
  type         = string
}

variable "node_pools" {
  description = <<-EOT
    Auto Mode built-in node pool names to enable.
    "general-purpose": standard workloads (frontend, backend pods).
    "system": reserved for system pods (CoreDNS, ALB controller, etc.)
    so application pods can't starve cluster critical components.
  EOT
  type    = list(string)
  default = ["general-purpose", "system"]
}

variable "cluster_public_access_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach the public Kubernetes API endpoint.
    Default 0.0.0.0/0 for learning project convenience (kubectl from
    anywhere). Restrict to your IP/32 for anything longer lived.
  EOT
  type    = list(string)
  default = ["0.0.0.0/0"]
}

variable "aws_account_id" {
  description = "AWS account ID. Not currently consumed inside this module — accepted for interface parity, was used in the old hand-rolled module for constructing ARNs inline."
  type        = string
}
