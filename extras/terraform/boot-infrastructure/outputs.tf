output "cloudfront_domain" {
  description = "CloudFront domain — add as CNAME for your domain in Cloudflare"
  value       = aws_cloudfront_distribution.boot.domain_name
}

output "cloudfront_id" {
  description = "CloudFront distribution ID (needed for cache invalidations)"
  value       = aws_cloudfront_distribution.boot.id
}

output "s3_bucket" {
  description = "S3 bucket name"
  value       = aws_s3_bucket.boot.id
}

output "acm_validation_records" {
  description = "Add these CNAME records in Cloudflare to validate the ACM certificate"
  value = {
    for dvo in aws_acm_certificate.boot.domain_validation_options : dvo.domain_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  }
}

output "dns_cname" {
  description = "Add this CNAME in Cloudflare once ACM is validated"
  value       = "${var.domain} → ${aws_cloudfront_distribution.boot.domain_name}"
}

output "ci_github_secrets" {
  description = "Add these to GitHub repository secrets for the release-netboot workflow"
  value = {
    NETBOOT_AWS_ACCESS_KEY_ID     = aws_iam_access_key.netboot_ci.id
    NETBOOT_AWS_SECRET_ACCESS_KEY = "(sensitive — run: terraform output -raw ci_secret_access_key)"
    NETBOOT_AWS_REGION            = var.bucket_region
    NETBOOT_S3_BUCKET             = "s3://${aws_s3_bucket.boot.id}/"
  }
  sensitive = false
}

output "ci_secret_access_key" {
  description = "Secret access key for the CI IAM user (add to GitHub secret NETBOOT_AWS_SECRET_ACCESS_KEY)"
  value       = aws_iam_access_key.netboot_ci.secret
  sensitive   = true
}

output "test_url" {
  description = "Test this URL after DNS propagates to verify the setup"
  value       = "http://${var.domain}/config.txt"
}
