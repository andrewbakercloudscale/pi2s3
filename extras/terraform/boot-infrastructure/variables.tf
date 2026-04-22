variable "domain" {
  description = "Domain name served by CloudFront (must match ACM cert and DNS CNAME)"
  type        = string
  default     = "boot.pi2s3.com"
}

variable "bucket_name" {
  description = "S3 bucket name for boot files (defaults to domain name)"
  type        = string
  default     = "boot.pi2s3.com"
}

variable "bucket_region" {
  description = "AWS region for the S3 bucket"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI profile to use (leave blank for default)"
  type        = string
  default     = ""
}
