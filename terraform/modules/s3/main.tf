# ─────────────────────────────────────────────────────────────────────────────
# S3 Module
# Media bucket for user uploads.
#
# KEY CHANGE FROM PHASE 2: the bucket policy grants access to the backend's
# IRSA role ARN instead of an EC2 instance role ARN. This is the entire
# point of IRSA — the bucket doesn't care whether the caller is EC2, EKS,
# or Lambda; it just trusts a specific IAM role ARN, and that role can now
# only be assumed by the exact ServiceAccount in the exact namespace
# specified in the role's trust policy (defined in the irsa module).
#
# bucket policy here = resource-based access control (who can touch this bucket)
# IRSA trust policy   = identity-based access control (who can become this role)
# Both must align for the pod to successfully read/write S3.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "media" {
  bucket        = var.s3_media_bucket_name
  force_destroy = true # learning project, allow clean teardown without manually emptying bucket

  tags = { Name = "${var.project}-media-${var.environment}" }
}

resource "aws_s3_bucket_public_access_block" "media" {
  bucket = aws_s3_bucket.media.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "media" {
  bucket = aws_s3_bucket.media.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "media" {
  bucket = aws_s3_bucket.media.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_cors_configuration" "media" {
  bucket = aws_s3_bucket.media.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "PUT", "POST"]
    allowed_origins = ["https://${var.domain_name}"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3600
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "media" {
  bucket = aws_s3_bucket.media.id

  rule {
    id     = "cleanup-old-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ── Bucket Policy — IRSA role access only ────────────────────────────────────
# Note: this references the backend's IRSA role ARN, created in the irsa
# module. The bucket trusts this role; the role's own trust policy (in the
# irsa module) restricts who can assume it to the penwave-backend
# ServiceAccount in the penwave namespace specifically.
resource "aws_s3_bucket_policy" "media" {
  bucket = aws_s3_bucket.media.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowBackendIRSARoleAccess"
        Effect = "Allow"
        Principal = {
          AWS = var.backend_irsa_role_arn
        }
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.media.arn,
          "${aws_s3_bucket.media.arn}/*"
        ]
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.media]
}
