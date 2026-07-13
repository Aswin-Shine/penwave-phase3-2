# ─────────────────────────────────────────────────────────────────────────────
# Root Outputs
# After `terraform apply`, run: aws eks update-kubeconfig --name <cluster_name>
# --region <region>  to configure kubectl, then verify with: kubectl get nodes
# ─────────────────────────────────────────────────────────────────────────────

output "cluster_name" {
  description = "EKS cluster name. Use with: aws eks update-kubeconfig --name <this> --region <region>"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = module.eks.cluster_endpoint
}

output "kubeconfig_command" {
  description = "Run this to configure kubectl against the new cluster."
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}"
}

output "oidc_provider_arn" {
  description = "IAM OIDC provider ARN — sanity check this matches what's in the AWS console under IAM > Identity providers."
  value       = module.eks.oidc_provider_arn
}

output "backend_irsa_role_arn" {
  description = "Paste this into the Helm chart's serviceAccount.annotations for the backend."
  value       = module.irsa.backend_role_arn
}

output "external_secrets_irsa_role_arn" {
  description = "Paste this into the External Secrets Operator's ServiceAccount annotation."
  value       = module.irsa.external_secrets_role_arn
}

output "alb_controller_irsa_role_arn" {
  description = <<-EOT
    ARN for the ALB Controller's ServiceAccount annotation:
      eks.amazonaws.com/role-arn: <this value>
    Applying this to an already-running deployment requires a pod restart —
    IRSA credentials are injected at pod start via a projected volume, not
    live-reloaded. Fast path if not using helm upgrade with this value set:
      kubectl annotate serviceaccount aws-load-balancer-controller \
        -n kube-system eks.amazonaws.com/role-arn=$(terraform output -raw alb_controller_irsa_role_arn) --overwrite
      kubectl delete pod -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
  EOT
  value = module.irsa.alb_controller_role_arn
}

output "secrets_manager_secret_name" {
  description = "Reference this in the ExternalSecret manifest's remoteRef.key."
  value       = module.irsa.secrets_manager_secret_name
}

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint — goes into the backend's DATABASE_URL via Kubernetes Secret/ConfigMap."
  value       = module.rds.endpoint
  sensitive   = true
}

output "redis_endpoint" {
  description = "Redis primary endpoint — goes into the backend's REDIS_URL."
  value       = module.redis.primary_endpoint_address
  sensitive   = true
}

output "s3_bucket_name" {
  description = "S3 media bucket name — goes into the backend's S3_BUCKET_NAME env var."
  value       = module.s3.bucket_name
}

output "vpc_id" {
  description = "VPC ID."
  value       = module.vpc.vpc_id
}

output "next_steps" {
  description = "What to run after terraform apply completes."
  value        = <<-EOT
    1. aws eks update-kubeconfig --name ${local.cluster_name} --region ${var.aws_region}
    2. kubectl get nodes                      # confirm Auto Mode nodes join (takes 2-5 min)
    3. kubectl create namespace penwave
    4. kubectl create namespace external-secrets
    5. kubectl create namespace argocd
    6. Install AWS Load Balancer Controller (see docs/eks.md), then annotate
       its ServiceAccount with the alb_controller_irsa_role_arn output and
       restart the pods — a bare `helm install` alone leaves it with no AWS
       identity and it will fail on the first real Ingress reconcile.
    7. Install External Secrets Operator (see docs/eks.md)
    8. Install ArgoCD (see docs/argocd.md)
    9. Apply Helm charts via ArgoCD Application manifests
  EOT
}
