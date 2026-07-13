# Penwave Phase 3 — Terraform Infrastructure Documentation

## Purpose

This document explains every module, every design decision, and every dependency in the Phase 3 Terraform codebase. It's written so you can defend each choice in an interview, not just run `terraform apply` and hope.

---

## 1. Why modules, and why this module boundary

The Phase 2 Terraform was a single flat directory: `networking.tf`, `rds.tf`, `elasticache.tf`, `s3.tf`, `iam.tf`, `security-groups.tf`. That works for one EC2 instance. It stops working the moment you need:

- Different environments (dev/staging/prod) with different VPC CIDRs without copy-pasting entire files
- To reason about one piece of infrastructure (e.g. "what does RDS depend on?") without reading every file
- To eventually publish a module to a private registry for reuse

Each module here has **one AWS service family** as its responsibility: `vpc` (networking only), `security` (security groups only), `rds`, `redis`, `s3`, `eks` (cluster + OIDC provider), `irsa` (IAM roles for service accounts + Secrets Manager). This is the single-responsibility principle applied to infrastructure — same reason you don't put authentication logic and payment logic in one file in application code.

---

## 2. Module dependency graph

Terraform builds a DAG (directed acyclic graph) from resource and module references — it does **not** execute top-to-bottom like a script. The actual apply order, inferred by Terraform from `module.x.y` references in `main.tf`, is:

```
vpc ──┬──> security ──┬──> rds
      │               ├──> redis
      │               └──> eks ──> irsa ──> s3
      └──────────────────────────────────────^
```

Concretely:

1. **vpc** has no dependencies — created first.
2. **security** depends on `vpc.vpc_id`.
3. **rds** and **redis** depend on `vpc` (subnet groups) and `security` (security group IDs). These two have no dependency on each other, so Terraform can create them in parallel.
4. **eks** depends on `vpc` (subnet IDs) and `security` (cluster/node SG IDs).
5. **irsa** depends on `eks.oidc_provider_arn` and `eks.oidc_provider_url` — it cannot be created until the OIDC provider exists.
6. **s3** depends on `irsa.backend_role_arn` for its bucket policy Principal.

### The circular dependency I had to design around

`s3`'s bucket policy needs to know the IRSA role's ARN (to grant it access). `irsa`'s IAM policy needs to know the S3 bucket's ARN (to scope the permission). If both modules referenced each other's **module outputs**, Terraform would refuse to build the graph — `module.s3` can't depend on `module.irsa` while `module.irsa` simultaneously depends on `module.s3`.

The fix: `irsa` does **not** read `module.s3.bucket_arn`. Instead, root `main.tf` constructs the ARN as a plain string from the bucket *name variable*:

```hcl
s3_media_bucket_arn = "arn:aws:s3:::${var.s3_media_bucket_name}"
```

This works because S3 bucket ARNs are 100% deterministic from the bucket name — there's no generated ID involved, unlike e.g. an RDS instance ARN which includes an AWS-assigned suffix in some cases. Both `s3` and `irsa` independently derive the identical ARN from the same input variable, breaking the cycle without losing correctness. This is a common pattern when two resources need mutual awareness — pick whichever side has a deterministic name and route through the variable instead of the resource output.

---

## 3. Module-by-module breakdown

### `modules/vpc`

Creates the VPC, 2 public + 2 private subnets (one pair per AZ — EKS and ALB both require multi-AZ), one NAT Gateway, route tables, and DB/cache subnet groups.

**Design decision — single NAT Gateway, not one per AZ:** A second NAT Gateway costs ~$32/month and exists purely for AZ-level NAT redundancy. For infrastructure you tear down within 48 hours, that redundancy has zero practical value — if the NAT's AZ fails during your 2-day window, you'd notice and could redeploy long before any real "outage" mattered to anyone. In a real production system you'd want one NAT per AZ; this is a documented, deliberate tradeoff, not an oversight.

**The EKS subnet tags matter functionally, not just cosmetically.** `kubernetes.io/role/elb` on public subnets and `kubernetes.io/role/internal-elb` on private subnets are how the AWS Load Balancer Controller auto-discovers which subnets to place load balancers in. Without these tags, ALB provisioning fails or requires manually specifying subnet IDs in every Ingress annotation.

### `modules/security`

Four security groups: `eks_cluster` (control plane ENIs), `eks_nodes` (worker nodes), `rds`, `elasticache`.

**Why `eks_nodes` has a self-referencing ingress rule** (`self = true`): EKS's VPC CNI plugin assigns pods IP addresses from the VPC subnet directly (not an overlay network like Calico/Flannel in other K8s distros). Pod-to-pod traffic on different nodes is genuinely node-to-node traffic at the security group level. Without `self = true`, pods on different nodes can't reach each other and you'll see DNS resolution failures or service-to-service call timeouts that look like application bugs but are actually security group misconfigurations.

**Why RDS/Redis SGs reference `eks_nodes` SG instead of a CIDR block:** referencing a security group ID as the source (rather than `10.0.0.0/16`) means the rule automatically tracks every current and future EKS node, regardless of IP. If Auto Mode scales out 5 more nodes tomorrow, they're automatically covered — no Terraform re-apply needed for the security group itself.

### `modules/rds`

Nearly identical to Phase 2, with two changes:

1. `deletion_protection = false` and `skip_final_snapshot = true` — Phase 2 had `deletion_protection = true` because that EC2 deployment was meant to run indefinitely. This is explicitly a 48-hour cluster; protecting against accidental deletion of something you're about to delete on purpose adds friction with no safety benefit.
2. `multi_az` is now a variable (default `false`) instead of hardcoded, so you can flip it on if you specifically want to practice RDS failover testing during your window.

### `modules/redis`

Unchanged from Phase 2's bug-fixed version (`aws_elasticache_replication_group`, not `aws_elasticache_cluster` — the cluster resource doesn't reliably support `auth_token` + TLS together). Snapshot retention dropped to 0 since there's no need to retain Redis snapshots for a cluster you're tearing down in 2 days.

### `modules/s3`

Same bucket configuration as Phase 2 (public access block, encryption, versioning, CORS, lifecycle rules) with one structural change: the bucket policy's `Principal` is the **IRSA role ARN** instead of an EC2 instance role ARN. This is the only change required on the S3 side to support the EKS migration — S3 doesn't know or care whether the caller is EC2 or EKS; it only cares about the IAM role ARN making the request.

### `modules/eks`

This is the module with the most genuinely new surface area versus Phase 2, because EKS Auto Mode is architecturally different from both classic EKS and from EC2.

**IAM roles needed for Auto Mode that didn't exist before:**

Classic EKS node groups need `AmazonEKSWorkerNodePolicy` + `AmazonEKS_CNI_Policy` + `AmazonEC2ContainerRegistryReadOnly` attached to a node IAM role, and you manage `aws_eks_node_group` resources yourself (instance types, scaling config, launch templates). Auto Mode replaces all of that with:

- `AmazonEKSWorkerNodeMinimalPolicy` (a slimmer permission set than the classic worker policy, since Auto Mode handles more internally)
- `AmazonEC2ContainerRegistryPullOnly` (pull-only, more restrictive than `ReadOnly`, which also allows some metadata operations Auto Mode doesn't need)
- No `aws_eks_node_group` resource at all — instead, the `compute_config` block inside `aws_eks_cluster` itself

The cluster IAM role also needs four Auto Mode-specific managed policies beyond the classic `AmazonEKSClusterPolicy`: `AmazonEKSComputePolicy`, `AmazonEKSBlockStoragePolicy`, `AmazonEKSLoadBalancingPolicy`, `AmazonEKSNetworkingPolicy`. These grant the control plane itself permission to provision EC2 instances, EBS volumes, ALBs/NLBs, and ENIs on your behalf — work that used to require you to set up the AWS Load Balancer Controller, EBS CSI driver, and Cluster Autoscaler as separate Helm installs with their own IRSA roles. Auto Mode collapses much of that into the control plane's own permissions.

**The OIDC provider — read this section twice, since it's the IRSA foundation:**

```hcl
data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]
}
```

Every EKS cluster has an OIDC issuer URL the instant it's created — it's baked into the cluster's identity. But **AWS IAM has no relationship with that issuer until you explicitly register it** via `aws_iam_openid_connect_provider`. Skip this resource and every `AssumeRoleWithWebIdentity` call from a pod fails with `InvalidIdentityToken`, because IAM literally has no public key material to validate the JWT signature against.

The `thumbprint_list` is fetched dynamically via the `tls_certificate` data source rather than hardcoded. AWS has rotated the underlying CA for EKS OIDC endpoints before; a hardcoded thumbprint silently breaks IRSA the next time that happens, and the failure mode (AssumeRoleWithWebIdentity AccessDenied) gives you no hint that the actual cause is a stale thumbprint. Fetching it at apply time means it's always current as of your last `terraform apply`.

**`node_security_group_id` is accepted by this module but not actually wired into `compute_config`.** EKS Auto Mode manages its own node security group internally — there's currently no Terraform argument to override it. The variable exists for interface consistency with the `security` module (so the module signature doesn't silently change if AWS adds this capability later, or if you switch to managed node groups) but is presently unused inside `eks/main.tf`. This is documented in the variable's description, not hidden.

### `modules/irsa`

This is the module you asked me to explain in depth, so the in-file comments are deliberately dense. Three things this module creates:

1. **Backend IRSA role** — trust policy pinned to `system:serviceaccount:penwave:penwave-backend`, with an inline policy granting S3 read/write/delete/list scoped to exactly the media bucket ARN (not `*`).
2. **External Secrets Operator IRSA role** — trust policy pinned to `system:serviceaccount:external-secrets:external-secrets`, with an inline policy granting `secretsmanager:GetSecretValue` and `DescribeSecret` scoped to `penwave/prod/*` (not all secrets in the account).
3. **The Secrets Manager secret itself** — Terraform writes `JWT_ACCESS_SECRET`, `JWT_REFRESH_SECRET`, `COOKIE_SECRET`, `METRICS_SECRET`, `GRAFANA_PASSWORD`, `DB_PASSWORD`, and `REDIS_AUTH_TOKEN` as a single JSON blob into one Secrets Manager secret.

**Why `StringEquals` and not `StringLike`** in the trust policy condition: `StringEquals` requires an exact match on the `sub` claim. `StringLike` would allow wildcard patterns — useful if you wanted one role assumable by multiple service accounts matching a pattern, but that's the opposite of what IRSA's security model is for. Every role here should be assumable by exactly one ServiceAccount in exactly one namespace. Using `StringLike` here would be a real security regression, not a stylistic choice.

**Why both `sub` and `aud` are checked in the condition:** `sub` ties the role to a specific ServiceAccount. `aud` (audience) ensures the token was actually issued for `sts.amazonaws.com` and not some other audience the EKS token projection mechanism could theoretically be configured to issue for. Checking only `sub` and not `aud` is a common omission in IRSA tutorials online — both should be present.

**Why Secrets Manager + External Secrets Operator instead of putting secrets directly in Helm `values.yaml` or Kubernetes Secrets created by Terraform:** A Kubernetes Secret is base64-encoded, not encrypted, when stored in etcd unless you've separately enabled etcd encryption at rest (EKS does this by default for newer clusters, but it's still just one layer). More importantly: if Terraform created `kubernetes_secret` resources directly, the secret values would be visible in Terraform state in plaintext (state files are not encrypted by default even with an S3 backend, unless you separately enable SSE on the state bucket). Routing through Secrets Manager means Terraform's *job* is just to write the value once to a service designed to store secrets, and ESO's *job* is to sync it into K8s — separation of concerns, and the value only needs to be treated as sensitive in one place (Secrets Manager's own encryption) rather than three (state file, Helm values, Git).

---

## 4. What's deliberately NOT in this Terraform

- **No ArgoCD installation** — ArgoCD is installed via Helm directly against the cluster (`helm install argocd ...`), not via Terraform's `helm` provider. Using the Terraform Helm provider to install cluster add-ons is a common anti-pattern: it conflates infrastructure provisioning (which changes rarely) with application/platform deployment (which changes often), and creates awkward apply-ordering problems when the Helm release needs CRDs that don't exist yet. ArgoCD's own install manifests handle this better.
- **No Kubernetes manifests** (Deployments, Services, Ingress) — those belong in the Helm charts, applied via ArgoCD, not Terraform. Terraform's job ends at "the cluster exists and IAM is wired correctly."
- **No DynamoDB table for state locking** — Terraform 1.10+'s S3-native locking (`use_lockfile = true`) replaced the classic S3+DynamoDB pattern. One less piece of infrastructure to provision and pay for.

---

## 5. How to actually run this

```bash
# One-time: create the state bucket (not managed by this Terraform itself —
# you can't have Terraform create the bucket it stores its own state in
# without a chicken-and-egg bootstrapping step)
aws s3api create-bucket --bucket penwave-terraform-state-<your-account-id> --region us-east-1
aws s3api put-bucket-versioning --bucket penwave-terraform-state-<your-account-id> \
  --versioning-configuration Status=Enabled

# Uncomment the backend block in providers.tf, fill in your bucket name

# Set sensitive values as environment variables (never in a committed file)
export TF_VAR_db_password="$(openssl rand -base64 24)"
export TF_VAR_redis_auth_token="$(openssl rand -hex 32)"
export TF_VAR_jwt_access_secret="$(openssl rand -hex 32)"
export TF_VAR_jwt_refresh_secret="$(openssl rand -hex 32)"
export TF_VAR_cookie_secret="$(openssl rand -hex 32)"
export TF_VAR_metrics_secret="$(openssl rand -hex 16)"
export TF_VAR_grafana_password="$(openssl rand -base64 16)"

cd terraform
terraform init
terraform plan -var-file=environments/prod/terraform.tfvars -out=tfplan
terraform apply tfplan

# Wait for EKS control plane (10-15 min) and Auto Mode nodes to join (2-5 min after)
aws eks update-kubeconfig --name penwave-eks-prod --region us-east-1
kubectl get nodes
```

## 6. Teardown (since you're running this for ≤2 days)

```bash
terraform destroy -var-file=environments/prod/terraform.tfvars
```

Order matters less here than on apply because Terraform reverses its own dependency graph automatically for destroy. The one thing to watch: if you manually created any Kubernetes resources (via `kubectl apply`, ArgoCD, or Helm) that provisioned AWS resources outside Terraform's knowledge — most importantly, any `Service` of `type: LoadBalancer` or `Ingress` that triggered the AWS Load Balancer Controller to create an ALB/NLB — **delete those Kubernetes resources first**, before running `terraform destroy`. Terraform doesn't know those load balancers exist (they were created by a controller running inside the cluster, not by Terraform), so destroying the VPC underneath a still-existing ALB will leave an orphaned load balancer billing you indefinitely, or cause the VPC deletion to fail with a dependency error because the ALB's ENIs are still attached to your subnets.

```bash
# Before terraform destroy:
kubectl delete ingress --all -n penwave
kubectl delete svc --all -n penwave  # only if any are type: LoadBalancer
# Wait ~1-2 min for the ALB controller to actually deprovision the ALB in AWS
# Verify in AWS console: EC2 > Load Balancers — should show none for this cluster
```
