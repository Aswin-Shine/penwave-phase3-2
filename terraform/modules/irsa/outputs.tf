output "backend_role_arn" {
  description = <<-EOT
    ARN of the backend's IRSA role.
    Used in two places downstream:
    1. The s3 module's bucket policy Principal (root main.tf wires this).
    2. The Helm chart's ServiceAccount annotation:
       eks.amazonaws.com/role-arn: <this value>
       on the penwave-backend ServiceAccount in the penwave namespace.
       Getting this annotation right is what makes EKS inject the
       AWS_ROLE_ARN and AWS_WEB_IDENTITY_TOKEN_FILE env vars into the pod.
  EOT
  value = aws_iam_role.backend.arn
}

output "external_secrets_role_arn" {
  description = "ARN of the External Secrets Operator's IRSA role. Goes on the external-secrets ServiceAccount annotation."
  value       = aws_iam_role.external_secrets.arn
}

output "alb_controller_role_arn" {
  description = <<-EOT
    ARN of the ALB Controller's IRSA role. Goes on the Helm chart's
    ServiceAccount annotation:
      serviceAccount.annotations."eks\.amazonaws\.com/role-arn": <this value>
    Requires a pod restart after annotating an already-running deployment —
    IRSA credentials are injected via a projected volume at pod start, not
    live-reloaded into a running container.
  EOT
  value = aws_iam_role.alb_controller.arn
}

output "secrets_manager_secret_arn" {
  description = "ARN of the AWS Secrets Manager secret containing app secrets. Referenced in the ExternalSecret Kubernetes manifest."
  value       = aws_secretsmanager_secret.app_secrets.arn
}

output "secrets_manager_secret_name" {
  description = "Name of the AWS Secrets Manager secret (used in ExternalSecret manifest's remoteRef.key)."
  value       = aws_secretsmanager_secret.app_secrets.name
}
