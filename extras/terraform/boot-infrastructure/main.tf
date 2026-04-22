# =============================================================
# boot-infrastructure/main.tf
#
# Creates the S3 + CloudFront infrastructure to serve
# Pi 5 HTTP netboot files at boot.pi2s3.com.
#
# The Pi 5 bootloader fetches over plain HTTP — CloudFront is
# configured to allow HTTP (not HTTPS-only) for this reason.
#
# Resources created:
#   - S3 bucket (private, CloudFront access via OAC)
#   - CloudFront distribution (HTTP + HTTPS, edge-cached globally)
#   - ACM TLS certificate (us-east-1, required for CloudFront)
#   - IAM user + access key for CI builds (write-only to the bucket)
#
# Usage:
#   cd extras/terraform/boot-infrastructure
#   cp terraform.tfvars.example terraform.tfvars   # fill in your values
#   terraform init
#   terraform plan
#   terraform apply
#
# After apply:
#   1. Add the DNS records from outputs to Cloudflare (ACM validation + CNAME)
#   2. Wait for ACM to validate (~2 min), then re-run: terraform apply
#   3. Add the CI credentials to GitHub Secrets (see outputs)
# =============================================================

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # Uncomment to store state in S3 (recommended for team use):
  # backend "s3" {
  #   bucket = "your-terraform-state-bucket"
  #   key    = "pi2s3/boot-infrastructure/terraform.tfstate"
  #   region = "af-south-1"
  # }
}

# Primary provider — where the S3 bucket lives
provider "aws" {
  region  = var.bucket_region
  profile = var.aws_profile
}

# ACM certificates for CloudFront must be in us-east-1
provider "aws" {
  alias   = "us_east_1"
  region  = "us-east-1"
  profile = var.aws_profile
}

# ── S3 bucket ─────────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "boot" {
  bucket = var.bucket_name
}

resource "aws_s3_bucket_public_access_block" "boot" {
  bucket                  = aws_s3_bucket.boot.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "boot" {
  bucket = aws_s3_bucket.boot.id
  versioning_configuration { status = "Disabled" }
}

# ── CloudFront Origin Access Control ──────────────────────────────────────────
# OAC lets CloudFront access the private S3 bucket via signed requests.
# The Pi never hits S3 directly — only CloudFront does.

resource "aws_cloudfront_origin_access_control" "boot" {
  name                              = "pi2s3-boot-${var.bucket_name}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Allow CloudFront to read from the bucket via OAC
resource "aws_s3_bucket_policy" "boot" {
  bucket     = aws_s3_bucket.boot.id
  depends_on = [aws_s3_bucket_public_access_block.boot]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudFrontServicePrincipal"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.boot.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.boot.arn
          }
        }
      }
    ]
  })
}

# ── ACM Certificate ───────────────────────────────────────────────────────────
# Must be in us-east-1 for CloudFront. Validate via DNS (Cloudflare).
# After terraform apply, add the CNAME records from outputs to Cloudflare,
# wait ~2 minutes, then run terraform apply again to complete validation.

resource "aws_acm_certificate" "boot" {
  provider          = aws.us_east_1
  domain_name       = var.domain
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}

# ── CloudFront distribution ───────────────────────────────────────────────────

resource "aws_cloudfront_distribution" "boot" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "pi2s3 HTTP netboot — ${var.domain}"
  aliases         = [var.domain]

  origin {
    domain_name              = aws_s3_bucket.boot.bucket_regional_domain_name
    origin_id                = "s3-boot"
    origin_access_control_id = aws_cloudfront_origin_access_control.boot.id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "s3-boot"

    # allow-all is REQUIRED: Pi 5 HTTP boot uses plain HTTP (not HTTPS)
    viewer_protocol_policy = "allow-all"

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }

    min_ttl     = 0
    default_ttl = 300   # 5 min — boot files change infrequently
    max_ttl     = 3600
    compress    = false # don't gzip — Pi bootloader fetches raw binaries
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate.boot.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

# ── IAM user for CI builds ────────────────────────────────────────────────────
# Used by GitHub Actions (release-netboot.yml) to upload boot files.
# Credentials are in outputs — add to GitHub repository secrets.

resource "aws_iam_user" "netboot_ci" {
  name = "pi2s3-netboot-ci"
  path = "/pi2s3/"
}

resource "aws_iam_user_policy" "netboot_ci" {
  name = "pi2s3-netboot-ci-s3-write"
  user = aws_iam_user.netboot_ci.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.boot.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.boot.arn
      },
      {
        Effect   = "Allow"
        Action   = ["cloudfront:CreateInvalidation"]
        Resource = "arn:aws:cloudfront::${data.aws_caller_identity.current.account_id}:distribution/${aws_cloudfront_distribution.boot.id}"
      }
    ]
  })
}

resource "aws_iam_access_key" "netboot_ci" {
  user = aws_iam_user.netboot_ci.name
}

data "aws_caller_identity" "current" {}
