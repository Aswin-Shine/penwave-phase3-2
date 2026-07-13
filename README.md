# Penwave Phase 3 — Terraform + Kubernetes/Helm (EKS, Auto Mode, IRSA)

This delivery covers two layers: the Terraform infrastructure (EKS Auto Mode cluster, IRSA roles, VPC, RDS, Redis, S3) and the Kubernetes/Helm application layer that runs on top of it. It does not include ArgoCD configuration or CI/CD pipeline changes; those are separate, later deliverables.

## What's in this zip

```
terraform/                          # See docs/terraform.md
├── main.tf / variables.tf / outputs.tf / providers.tf
├── environments/prod/terraform.tfvars
└── modules/{vpc,security,rds,redis,s3,eks,irsa}/

k8s/manifests/                      # Raw Kubernetes manifests — see docs/kubernetes.md
├── namespace/
├── backend/      (ServiceAccount w/ IRSA, Deployment, Service, HPA, PDB, NetworkPolicy)
├── frontend/     (ServiceAccount, Deployment, Service, HPA, PDB)
├── configmap/
├── external-secrets/   (ClusterSecretStore, ExternalSecret, manual connection-strings Secret)
└── ingress/

helm/                                # Same application layer, templated
├── penwave-backend/
├── penwave-frontend/
└── penwave-ingress/

docs/
├── terraform.md                      # Terraform module-by-module explanation + runbook
├── irsa-deep-dive.md                 # Standalone IRSA explainer
└── kubernetes.md                     # K8s/Helm layer explanation + runbook
```


## Before you run anything

1. **Create the Terraform state bucket** (one-time, can't be done by the Terraform that depends on it):
   ```bash
   aws s3api create-bucket --bucket penwave-terraform-state-797416042676 --region us-east-1
   aws s3api put-bucket-versioning --bucket penwave-terraform-state-797416042676 --versioning-configuration Status=Enabled
   ```
   Then uncomment the `backend "s3" {}` block in `terraform/providers.tf` and fill in your bucket name.

2. **Set sensitive variables as environment variables** — never in a committed file. This is the direct fix for the Phase 2 incident where `prod.tfvars` was committed with real credentials:
   ```bash
   export TF_VAR_db_password="$(openssl rand -base64 24)"
   export TF_VAR_redis_auth_token="$(openssl rand -hex 32)"
   export TF_VAR_jwt_access_secret="$(openssl rand -hex 32)"
   export TF_VAR_jwt_refresh_secret="$(openssl rand -hex 32)"
   export TF_VAR_cookie_secret="$(openssl rand -hex 32)"
   export TF_VAR_metrics_secret="$(openssl rand -hex 16)"
   export TF_VAR_grafana_password="$(openssl rand -base64 16)"
   ```

3. **Edit `terraform/environments/prod/terraform.tfvars`**: change `s3_media_bucket_name` to something globally unique (S3 bucket names are unique across ALL AWS accounts, not just yours), and `dockerhub_username` to your actual Docker Hub username.

## Running it

```bash
cd terraform
terraform init
terraform plan -var-file=environments/prod/terraform.tfvars -out=tfplan
terraform apply tfplan
```

Expect the EKS control plane to take 10–15 minutes to provision, and Auto Mode nodes to join 2–5 minutes after that. Full timeline and verification steps are in `docs/terraform.md` section 5.

## Kubernetes layer — before you apply

Three things are real, manual prerequisites, not optional polish:

1. **AWS Load Balancer Controller and External Secrets Operator must be installed via Helm before the manifests in `k8s/manifests/ingress/` and `k8s/manifests/external-secrets/` will do anything.** Install commands are in the comments at the top of `ingress.yaml` and `clustersecretstore.yaml` respectively.
2. **Replace every `REPLACE_*` placeholder** in `backend/serviceaccount.yaml` (IRSA role ARN), `ingress/ingress.yaml` (ACM cert ARN), and both Deployments (image repository/tag) — or the equivalent `--set` flags if using Helm.
3. **The `penwave-backend-connection-strings` Secret is intentionally not synced by External Secrets Operator** — it's created manually because it assembles a Terraform output (RDS/Redis endpoint) with a Secrets Manager value (password) into one connection string. See `docs/kubernetes.md` section 2 for the exact script.

**One unresolved issue carried over from Phase 1/2 and now more consequential:** `NEXT_PUBLIC_API_URL` is still baked into the frontend's client JS bundle at Docker build time, not read at runtime. Setting it as a Kubernetes env var (which the frontend Deployment does, for SSR paths) does not fix browser-side fetch calls. See `docs/kubernetes.md` section 4 for the full explanation — the actual fix is an application code change (relative `/api` path in `api-client.ts`) that wasn't part of this delivery's scope.

## Tearing down (you said ≤2 days)

**Read `docs/terraform.md` section 6 before destroying** — there's a real gotcha around AWS Load Balancer Controller-created ALBs that Terraform doesn't know about and won't clean up automatically if you've deployed any `Ingress` or `type: LoadBalancer` Service via kubectl/Helm/ArgoCD in the meantime.

```bash
terraform destroy -var-file=environments/prod/terraform.tfvars
```

## What I verified vs. what I couldn't

I don't have a Terraform binary available in this environment (network egress to `releases.hashicorp.com` is blocked) and could not run an actual `terraform validate` or `terraform plan`. [Certain]

What I did check manually instead, since "should plan" is not the same as "I confirmed it plans":
- Brace balance across every `.tf` file (no unclosed blocks)
- Every module call in root `main.tf` supplies all required (non-default) variables for that module — checked against each module's actual `variables.tf`
- Every `module.x.y` reference in `main.tf` and `outputs.tf` resolves to an output that actually exists in that module's `outputs.tf` — checked all 19 cross-module references individually
- No duplicate resource addresses within any single module
- The circular dependency between `s3` and `irsa` modules (each needing the other's resource ARN) is structurally broken by deriving both ARNs from the same input variable rather than from each other's outputs

What I could **not** verify: actual AWS API behavior (e.g. whether `AmazonEKSWorkerNodeMinimalPolicy` is the exact correct managed policy name as of today, whether `compute_config.node_pools` accepts exactly `["general-purpose", "system"]` as values, or whether EKS Auto Mode's current API surface matches what's described here). EKS Auto Mode is a relatively recent feature and AWS's API for it could have changed details since my training data — [Likely accurate based on documentation patterns at the time of my knowledge cutoff, but you should run `terraform plan` yourself and read any error messages closely before trusting this blindly, especially for the `eks` and `irsa` modules specifically].

If `terraform plan` throws an error on the `aws_eks_cluster.main.compute_config` block or the managed policy ARNs in `modules/eks/main.tf`, that's the most likely place for drift between what I wrote and AWS's current actual API — paste me the exact error and I'll fix it.










kubectl get ingress test-ingress -n test-ingress
NAME           CLASS   HOSTS   ADDRESS                                                                   PORTS   AGE
test-ingress   alb     *       k8s-testingr-testingr-a51d05cf62-1176175504.us-east-1.elb.amazonaws.com   80      2m38s



-------------------------------------------------------------------------------------
# Prerequisite — confirm BEFORE running helm, not after a crash loop:
#   1. kubectl get nodes -> at least one node Ready
#   2. kubectl get nodeclass default -o yaml | grep -A6 conditions -> InstanceProfileReady: True
#      If False, see "instance-profile workaround" below FIRST.

# UNCONFIRMED whether still required once --set vpcId is used — test this
# on next fresh cluster before trusting either way [Guessing]:
NODE_ID=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
aws ec2 modify-instance-metadata-options --instance-id $NODE_ID \
  --http-put-response-hop-limit 2 --http-tokens required

# Terraform must already be applied — this reads real outputs, not placeholders
CLUSTER_NAME=$(terraform output -raw cluster_name)
VPC_ID=$(terraform output -raw vpc_id)
ALB_ROLE_ARN=$(terraform output -raw alb_controller_irsa_role_arn)

helm repo add eks https://aws.github.io/eks-charts 2>/dev/null
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set region=us-east-1 \
  --set vpcId=$VPC_ID \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set-string 'serviceAccount.annotations.eks\.amazonaws\.com/role-arn'=$ALB_ROLE_ARN
  

  --------------------------------------------------------------------------------------------------------