# ─────────────────────────────────────────────────────────────────────────────
# IRSA Module — IAM Roles for Service Accounts
#
# THE MECHANISM, restated precisely for this module's code:
#
#   1. EKS's OIDC provider (registered in the eks module) lets AWS IAM trust
#      JWTs issued by the cluster's own token issuer.
#   2. Each role below has a trust policy with a Condition that pins the role
#      to ONE specific "system:serviceaccount:<namespace>:<sa-name>" string.
#   3. When a pod with that exact ServiceAccount starts, EKS's mutating
#      webhook injects a projected token (JWT) at
#      /var/run/secrets/eks.amazonaws.com/serviceaccount/token, refreshed
#      automatically before expiry.
#   4. The AWS SDK inside the pod's container reads AWS_ROLE_ARN and
#      AWS_WEB_IDENTITY_TOKEN_FILE env vars (auto-injected by EKS Pod
#      Identity webhook when the ServiceAccount has the
#      eks.amazonaws.com/role-arn annotation) and calls
#      sts:AssumeRoleWithWebIdentity.
#   5. STS validates the JWT signature against the OIDC provider's public
#      keys, checks the "sub" claim matches the trust policy condition
#      exactly, and if so, returns temporary credentials (1hr default,
#      auto-refreshed by the SDK before expiry).
#
# WHY THIS MATTERS OPERATIONALLY: a compromised pod running under a
# DIFFERENT ServiceAccount (e.g. frontend) cannot assume the backend's S3
# role even if it tries — the "sub" claim in ITS token won't match the
# Condition in the backend role's trust policy. This is the entire security
# value over a shared node-level IAM role.
#
# THREE ROLES CREATED HERE:
#   - backend role: S3 media bucket read/write (the only AWS API Penwave's
#     app code calls directly)
#   - external-secrets role: reads AWS Secrets Manager to populate
#     Kubernetes Secrets (used by the External Secrets Operator, not by
#     application code)
#   - (argocd_namespace variable accepted for future use — ArgoCD itself
#     doesn't need AWS API access in this architecture since it only talks
#     to the Kubernetes API and Git, but the namespace is wired through in
#     case you add an IRSA-backed integration later, e.g. ArgoCD Notifications
#     posting to SNS)
# ─────────────────────────────────────────────────────────────────────────────

# ── Backend Role: S3 Media Access ─────────────────────────────────────────────
resource "aws_iam_role" "backend" {
  name = "${var.project}-irsa-backend-${var.environment}"

  # This is the single most important block in the entire IRSA setup.
  # StringEquals (not StringLike) is intentional — it is an EXACT match
  # requirement. The "sub" claim format is fixed by EKS:
  #   system:serviceaccount:<namespace>:<service-account-name>
  # Get the namespace or SA name wrong here and AssumeRoleWithWebIdentity
  # fails with AccessDenied — the JWT is valid, but the trust policy
  # condition simply doesn't match, and AWS gives no further detail in
  # the error beyond "not authorized to perform sts:AssumeRoleWithWebIdentity".
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = var.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${var.oidc_provider_url}:sub" = "system:serviceaccount:${var.backend_namespace}:${var.backend_sa_name}"
            "${var.oidc_provider_url}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = { Name = "${var.project}-irsa-backend-${var.environment}" }
}

# Scoped S3 permissions — same bucket ARN the s3 module's bucket policy
# trusts. Built from the bucket NAME variable (not a module output) to
# avoid a circular module dependency; see modules/s3/variables.tf for the
# matching note on the other side of this relationship.
resource "aws_iam_role_policy" "backend_s3" {
  name = "${var.project}-irsa-backend-s3-${var.environment}"
  role = aws_iam_role.backend.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "MediaBucketReadWrite"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          var.s3_media_bucket_arn,
          "${var.s3_media_bucket_arn}/*"
        ]
      }
    ]
  })
}

# ── External Secrets Operator Role: Secrets Manager Read ─────────────────────
# ESO runs as its own pod with its own ServiceAccount in the
# external-secrets namespace. It needs read-only access to Secrets Manager
# to sync values into Kubernetes Secrets. Application pods never touch
# Secrets Manager directly — they only ever read the Kubernetes Secret
# that ESO creates and keeps in sync.
resource "aws_iam_role" "external_secrets" {
  name = "${var.project}-irsa-external-secrets-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = var.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${var.oidc_provider_url}:sub" = "system:serviceaccount:${var.external_secrets_namespace}:external-secrets"
            "${var.oidc_provider_url}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = { Name = "${var.project}-irsa-external-secrets-${var.environment}" }
}

resource "aws_iam_role_policy" "external_secrets_sm" {
  name = "${var.project}-irsa-external-secrets-sm-${var.environment}"
  role = aws_iam_role.external_secrets.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadPenwaveSecrets"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        # Scoped to secrets prefixed with this project/environment only —
        # NOT secretsmanager:* on Resource "*". A compromised ESO pod
        # still can't read unrelated secrets in the same AWS account.
        Resource = "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:${var.project}/${var.environment}/*"
      },
      {
        Sid      = "ListSecretsForDiscovery"
        Effect   = "Allow"
        Action   = ["secretsmanager:ListSecrets"]
        Resource = "*" # ListSecrets does not support resource-level scoping
      }
    ]
  })
}

# ── ALB Controller Role: Elastic Load Balancing management ───────────────────
# Added after the fact — this role did NOT exist when the ALB Controller was
# first installed, which is why it started cleanly (webhook/leader-election
# succeed via the Kubernetes API, not AWS) but would have failed with
# AccessDenied on the first real Ingress reconcile, since the ServiceAccount
# had no eks.amazonaws.com/role-arn annotation and therefore no AWS identity.
#
# Policy document is the upstream project's own iam_policy.json, fetched
# directly from kubernetes-sigs/aws-load-balancer-controller (main branch)
# rather than reconstructed by hand — this policy is long and version
# sensitive, and a hand-typed omission (e.g. missing one
# elasticloadbalancing:* action) fails silently until the specific code path
# needing it is exercised, which is exactly the class of bug this project has
# already lost time to twice this session.
resource "aws_iam_role" "alb_controller" {
  name = "${var.project}-irsa-alb-controller-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = var.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${var.oidc_provider_url}:sub" = "system:serviceaccount:${var.alb_controller_namespace}:${var.alb_controller_sa_name}"
            "${var.oidc_provider_url}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = { Name = "${var.project}-irsa-alb-controller-${var.environment}" }
}

# Upstream AWSLoadBalancerControllerIAMPolicy, verbatim, fetched from
# https://github.com/kubernetes-sigs/aws-load-balancer-controller/blob/main/docs/install/iam_policy.json
resource "aws_iam_role_policy" "alb_controller" {
  name = "${var.project}-irsa-alb-controller-${var.environment}"
  role = aws_iam_role.alb_controller.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["iam:CreateServiceLinkedRole"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "iam:AWSServiceName" = "elasticloadbalancing.amazonaws.com"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeAccountAttributes",
          "ec2:DescribeAddresses",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeInternetGateways",
          "ec2:DescribeVpcs",
          "ec2:DescribeVpcPeeringConnections",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeInstances",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeTags",
          "ec2:GetCoipPoolUsage",
          "ec2:DescribeCoipPools",
          "ec2:GetSecurityGroupsForVpc",
          "ec2:DescribeIpamPools",
          "ec2:DescribeRouteTables",
          "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:DescribeLoadBalancerAttributes",
          "elasticloadbalancing:DescribeListeners",
          "elasticloadbalancing:DescribeListenerCertificates",
          "elasticloadbalancing:DescribeSSLPolicies",
          "elasticloadbalancing:DescribeRules",
          "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DescribeTargetGroupAttributes",
          "elasticloadbalancing:DescribeTargetHealth",
          "elasticloadbalancing:DescribeTags",
          "elasticloadbalancing:DescribeTrustStores",
          "elasticloadbalancing:DescribeListenerAttributes",
          "elasticloadbalancing:DescribeCapacityReservation"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "cognito-idp:DescribeUserPoolClient",
          "acm:ListCertificates",
          "acm:DescribeCertificate",
          "iam:ListServerCertificates",
          "iam:GetServerCertificate",
          "waf-regional:GetWebACL",
          "waf-regional:GetWebACLForResource",
          "waf-regional:AssociateWebACL",
          "waf-regional:DisassociateWebACL",
          "wafv2:GetWebACL",
          "wafv2:GetWebACLForResource",
          "wafv2:AssociateWebACL",
          "wafv2:DisassociateWebACL",
          "shield:GetSubscriptionState",
          "shield:DescribeProtection",
          "shield:CreateProtection",
          "shield:DeleteProtection"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:CreateSecurityGroup"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:CreateTags"]
        Resource = "arn:aws:ec2:*:*:security-group/*"
        Condition = {
          StringEquals = {
            "ec2:CreateAction" = "CreateSecurityGroup"
          }
          Null = {
            "aws:RequestTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:CreateTags", "ec2:DeleteTags"]
        Resource = "arn:aws:ec2:*:*:security-group/*"
        Condition = {
          Null = {
            "aws:RequestTag/elbv2.k8s.aws/cluster"  = "true"
            "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:DeleteSecurityGroup"
        ]
        Resource = "*"
        Condition = {
          Null = {
            "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:CreateLoadBalancer",
          "elasticloadbalancing:CreateTargetGroup"
        ]
        Resource = "*"
        Condition = {
          Null = {
            "aws:RequestTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:CreateListener",
          "elasticloadbalancing:DeleteListener",
          "elasticloadbalancing:CreateRule",
          "elasticloadbalancing:DeleteRule"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:AddTags",
          "elasticloadbalancing:RemoveTags"
        ]
        Resource = [
          "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*",
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/net/*/*",
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/app/*/*"
        ]
        Condition = {
          Null = {
            "aws:RequestTag/elbv2.k8s.aws/cluster"  = "true"
            "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:AddTags",
          "elasticloadbalancing:RemoveTags"
        ]
        Resource = [
          "arn:aws:elasticloadbalancing:*:*:listener/net/*/*/*",
          "arn:aws:elasticloadbalancing:*:*:listener/app/*/*/*",
          "arn:aws:elasticloadbalancing:*:*:listener-rule/net/*/*/*",
          "arn:aws:elasticloadbalancing:*:*:listener-rule/app/*/*/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:ModifyLoadBalancerAttributes",
          "elasticloadbalancing:SetIpAddressType",
          "elasticloadbalancing:SetSecurityGroups",
          "elasticloadbalancing:SetSubnets",
          "elasticloadbalancing:DeleteLoadBalancer",
          "elasticloadbalancing:ModifyTargetGroup",
          "elasticloadbalancing:ModifyTargetGroupAttributes",
          "elasticloadbalancing:DeleteTargetGroup",
          "elasticloadbalancing:ModifyListenerAttributes",
          "elasticloadbalancing:ModifyCapacityReservation",
          "elasticloadbalancing:ModifyIpPools"
        ]
        Resource = "*"
        Condition = {
          Null = {
            "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["elasticloadbalancing:AddTags"]
        Resource = [
          "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*",
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/net/*/*",
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/app/*/*"
        ]
        Condition = {
          StringEquals = {
            "elasticloadbalancing:CreateAction" = [
              "CreateTargetGroup",
              "CreateLoadBalancer"
            ]
          }
          Null = {
            "aws:RequestTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:RegisterTargets",
          "elasticloadbalancing:DeregisterTargets"
        ]
        Resource = "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*"
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:SetWebAcl",
          "elasticloadbalancing:ModifyListener",
          "elasticloadbalancing:AddListenerCertificates",
          "elasticloadbalancing:RemoveListenerCertificates",
          "elasticloadbalancing:ModifyRule",
          "elasticloadbalancing:SetRulePriorities"
        ]
        Resource = "*"
      }
    ]
  })
}

# ── AWS Secrets Manager: application secrets ──────────────────────────────────
# Terraform writes these here. ESO reads them at deploy time and creates
# Kubernetes Secrets from them. Pods mount the K8s Secret as env vars —
# they never call Secrets Manager directly, and the raw value never
# appears in a Helm values file or Git history.
resource "aws_secretsmanager_secret" "app_secrets" {
  name                    = "${var.project}/${var.environment}/app-secrets"
  description             = "Penwave application secrets — synced into Kubernetes by External Secrets Operator"
  recovery_window_in_days = 0 # learning project, allow immediate deletion on teardown

  tags = { Name = "${var.project}-app-secrets-${var.environment}" }
}

resource "aws_secretsmanager_secret_version" "app_secrets" {
  secret_id = aws_secretsmanager_secret.app_secrets.id

  secret_string = jsonencode({
    JWT_ACCESS_SECRET  = var.jwt_access_secret
    JWT_REFRESH_SECRET = var.jwt_refresh_secret
    COOKIE_SECRET       = var.cookie_secret
    METRICS_SECRET      = var.metrics_secret
    GRAFANA_PASSWORD    = var.grafana_password
    DB_PASSWORD          = var.db_password
    REDIS_AUTH_TOKEN    = var.redis_auth_token
  })
}
