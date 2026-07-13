# IRSA Deep Dive — Penwave Phase 3

You said you couldn't confidently answer "why IRSA exists instead of just putting IAM credentials [in a Secret]." This doc is written to close that gap completely, using the actual Terraform you now have.

## The three bad options IRSA replaces

**Option 1 — hardcoded credentials in a Kubernetes Secret:**
```yaml
apiVersion: v1
kind: Secret
data:
  AWS_ACCESS_KEY_ID: <base64>
  AWS_SECRET_ACCESS_KEY: <base64>
```
Problems: these are long-lived (don't expire until you manually rotate them), visible in plaintext if etcd encryption isn't enabled, and if leaked (logged accidentally, committed to git, exfiltrated from a compromised pod), the attacker has standing access until someone notices and rotates the key. There is no automatic expiry.

**Option 2 — IAM role attached to the EC2 node, inherited by all pods:**
This is exactly what Penwave's Phase 2 EC2 deployment did — `aws_iam_instance_profile` on the single EC2 instance, and the backend process picked up credentials from the instance metadata service automatically. It worked because there was only one application process on that instance. On EKS, multiple pods share a node. If the node has an IAM role with S3 access, **every pod on that node can call the EC2 instance metadata service and get those same S3 credentials** — including a compromised nginx sidecar, a crashed-and-redeployed third-party Helm chart, or literally any container someone runs on that node. There's no pod-level boundary.

**Option 3 — IRSA:**
Pod-specific, auto-rotating, cryptographically tied to a Kubernetes ServiceAccount identity rather than a network location (the node).

## The mechanism, traced end to end through your actual Terraform

### Step 1: The cluster has an OIDC issuer the moment it's created

```hcl
# modules/eks/main.tf
resource "aws_eks_cluster" "main" {
  # ...
}
```

The instant this resource exists, AWS has assigned it an OIDC issuer URL — something like `https://oidc.eks.us-east-1.amazonaws.com/id/A1B2C3D4E5F6`. This is exposed via `aws_eks_cluster.main.identity[0].oidc[0].issuer`. This issuer can sign JWTs. But AWS IAM, a completely separate service, has no idea this issuer exists or that it should be trusted — yet.

### Step 2: You register that issuer with IAM

```hcl
# modules/eks/main.tf
resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]
}
```

This is the bridge. After this resource exists, IAM knows: "JWTs signed by this specific issuer, with `sts.amazonaws.com` as the audience, are valid and can be cryptographically verified using this CA thumbprint." Without this resource, the issuer exists but IAM has never heard of it.

### Step 3: You create an IAM role that only trusts JWTs claiming to be a specific ServiceAccount

```hcl
# modules/irsa/main.tf
resource "aws_iam_role" "backend" {
  assume_role_policy = jsonencode({
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }   # the bridge from step 2
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${var.oidc_provider_url}:sub" = "system:serviceaccount:penwave:penwave-backend"
          "${var.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}
```

Read the Condition literally: this role can ONLY be assumed by a JWT whose `sub` claim is exactly the string `system:serviceaccount:penwave:penwave-backend`. Not `penwave-frontend`. Not `penwave-backend` in a different namespace. Exactly that namespace, exactly that ServiceAccount name.

### Step 4: At pod startup, EKS injects a token matching that exact identity

When you deploy a pod with `serviceAccountName: penwave-backend` in the `penwave` namespace, and that ServiceAccount has the annotation `eks.amazonaws.com/role-arn: <backend role ARN>`, EKS's Pod Identity webhook does two things automatically:

1. Mounts a projected token at `/var/run/secrets/eks.amazonaws.com/serviceaccount/token` — a short-lived JWT (default 24h, auto-refreshed well before expiry) whose `sub` claim is exactly `system:serviceaccount:penwave:penwave-backend`, signed by the cluster's OIDC issuer from Step 1.
2. Injects two environment variables into the pod: `AWS_ROLE_ARN` (the role ARN from the annotation) and `AWS_WEB_IDENTITY_TOKEN_FILE` (the path to that mounted token).

### Step 5: The AWS SDK does the actual exchange, transparently

Any AWS SDK (Node.js, Python, Go — doesn't matter) that sees `AWS_WEB_IDENTITY_TOKEN_FILE` set automatically calls:

```
sts:AssumeRoleWithWebIdentity(
  RoleArn = $AWS_ROLE_ARN,
  WebIdentityToken = <contents of the token file>
)
```

STS validates the JWT signature using the OIDC provider's public keys (registered in Step 2), checks the `sub` and `aud` claims against the role's trust policy Condition (Step 3), and if everything matches, returns temporary credentials — access key, secret key, session token — valid for up to 1 hour, which the SDK caches and auto-refreshes before expiry. Your application code never sees a static credential. It just calls `s3.getObject(...)` and the SDK handles all of this invisibly.

## Where this actually breaks in practice (so you recognize it when it happens)

**Symptom: `AccessDenied` on `AssumeRoleWithWebIdentity`, but the pod is running fine otherwise.**
Almost always a `sub` claim mismatch. Check: does the ServiceAccount name in your Helm `values.yaml` exactly match `backend_sa_name` in the Terraform (`penwave-backend`)? Does the namespace match `backend_namespace` (`penwave`)? A single typo here (e.g. `penwave-backend-api` vs `penwave-backend`) produces this exact failure with no other clue in the error message.

**Symptom: pod falls back to node-level permissions instead of failing outright — looks like it's working but isn't actually using IRSA.**
This happens if `automountServiceAccountToken` is explicitly set to `false` somewhere in the pod spec, or if the ServiceAccount annotation is missing entirely. The SDK's credential provider chain falls through to the EC2 instance metadata service (which Auto Mode nodes do have, for their own node-level role) and silently uses that instead. You won't get an error — you'll just be using broader permissions than you think you are. This is the most dangerous failure mode because it doesn't announce itself.

**Symptom: works in `kubectl exec` testing but fails when actually deployed.**
Usually means you tested AWS CLI calls from inside a debug pod that happened to have a different ServiceAccount (e.g. `default`) than the one your actual Deployment uses. The `default` ServiceAccount has no IRSA annotation, so it falls back to node credentials — which might still let an S3 call succeed if the node role happens to have broader permissions, masking the fact that the *intended* pod's ServiceAccount wiring is broken.

## What you should be able to say in an interview now

"IRSA exists because EC2-instance-level IAM roles give every pod on that node the same blast radius — there's no way to scope access per-workload. IRSA uses the cluster's OIDC identity to let each pod assume a role through STS's `AssumeRoleWithWebIdentity`, with the trust policy's `sub` claim condition pinning that role to one exact ServiceAccount in one exact namespace. Credentials are temporary, auto-rotate hourly, and a compromised pod under a different ServiceAccount simply cannot produce a JWT that satisfies another role's trust policy condition — so the security boundary is cryptographic, not just network-based."
