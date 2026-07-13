output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "oidc_provider_arn" {
  description = "IAM OIDC provider ARN. Used in IRSA role trust policies."
  value       = module.eks.oidc_provider_arn
}

output "oidc_provider_url" {
  description = <<-EOT
    OIDC issuer URL WITHOUT the https:// prefix, matching the exact
    behavior of the old hand-rolled module's output. IAM trust policy
    Condition keys require the bare host+path form. The registry module's
    own cluster_oidc_issuer_url output returns the full https:// URL
    unstripped — this replace() preserves the contract every consumer
    (modules/irsa) was built against.
  EOT
  value       = replace(module.eks.cluster_oidc_issuer_url, "https://", "")
}

output "cluster_primary_security_group_id" {
  description = <<-EOT
    AWS's auto-generated primary cluster security group
    (eks-cluster-sg-<cluster-name>-<suffix>). Confirmed via live NodeClass
    inspection (kubectl get nodeclass default -o yaml) that Auto Mode
    attaches THIS security group to nodes — NOT modules/security's
    eks_nodes SG, despite that SG being tagged for Auto Mode discovery and
    being what RDS/Redis ingress rules currently reference. Root main.tf
    uses this output to grant RDS/Redis ingress from the SG nodes actually
    carry, since modules/security's eks_nodes SG has nothing attached to
    it under Auto Mode and was never a valid ingress source for real
    traffic.
  EOT
  value       = module.eks.cluster_primary_security_group_id
}
