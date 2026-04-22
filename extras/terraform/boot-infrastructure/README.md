# boot-infrastructure — Terraform

Creates the S3 + CloudFront infrastructure that serves Pi 5 HTTP netboot files at `boot.pi2s3.com`.

## What it creates

| Resource | Purpose |
|----------|---------|
| S3 bucket `boot.pi2s3.com` | Private bucket storing `kernel8.img`, `initrd.img`, `config.txt`, `cmdline.txt` |
| CloudFront OAC | Lets CloudFront fetch from the private S3 bucket via signed requests |
| CloudFront distribution | Global CDN — serves files over HTTP (required for Pi boot) and HTTPS |
| ACM certificate | TLS cert for `boot.pi2s3.com` in us-east-1 (required for CloudFront) |
| IAM user `pi2s3-netboot-ci` | Write-only access to the bucket, for GitHub Actions uploads |

## Terraform deploy

```bash
cd extras/terraform/boot-infrastructure

# 1. Copy and fill in variables
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars if needed (defaults are fine for most setups)

# 2. Init and plan
terraform init
terraform plan

# 3. First apply — creates everything except ACM validation
terraform apply
```

After the first `apply`, Terraform outputs DNS records you need to add in Cloudflare **before it can finish**:

```
acm_validation_records = {
  "boot.pi2s3.com" = {
    name  = "_abc123.boot.pi2s3.com."
    type  = "CNAME"
    value = "_xyz789.acm-validations.aws."
  }
}
```

Add that CNAME in Cloudflare (set proxy to **DNS only / grey cloud**), wait ~2 minutes, then run apply again — ACM will be validated and CloudFront will finish creating.

```bash
# 4. Add ACM validation CNAME in Cloudflare, then:
terraform apply   # completes CloudFront provisioning (~10 min first time)
```

## DNS records to add in Cloudflare (after apply)

| Type | Name | Value | Proxy |
|------|------|-------|-------|
| CNAME | `_abc123.boot` | `_xyz789.acm-validations.aws.` | DNS only |
| CNAME | `boot` | `xxxxxxxxxxxx.cloudfront.net` | DNS only |

The exact values come from `terraform output`.

> **Proxy must be OFF** (grey cloud) for both records. CloudFront handles the CDN — Cloudflare proxying on top will break it.

## GitHub Actions secrets

After apply, add these secrets to your GitHub repository (`Settings → Secrets → Actions`):

```bash
terraform output ci_github_secrets          # key ID, region, bucket
terraform output -raw ci_secret_access_key  # secret key (sensitive)
```

| Secret name | Value |
|-------------|-------|
| `NETBOOT_AWS_ACCESS_KEY_ID` | from `ci_github_secrets` |
| `NETBOOT_AWS_SECRET_ACCESS_KEY` | from `ci_secret_access_key` |
| `NETBOOT_AWS_REGION` | `us-east-1` (or your bucket region) |

## Test

```bash
curl -I http://boot.pi2s3.com/config.txt
# Should return: HTTP/1.1 200 OK (or 403 until you upload files)

# Upload boot files:
bash ~/pi2s3/extras/build-netboot-image.sh --upload s3://boot.pi2s3.com/

# Test again:
curl http://boot.pi2s3.com/config.txt
```

## Tear down

```bash
# Empty the bucket first (terraform can't delete non-empty buckets)
aws s3 rm s3://boot.pi2s3.com/ --recursive

terraform destroy
```

---

## Manual steps (no Terraform)

If you prefer to set this up via the AWS Console:

### 1. Create S3 bucket

1. Go to S3 → **Create bucket**
2. Bucket name: `boot.pi2s3.com`
3. Region: `us-east-1` (or your preference)
4. Block all public access: **ON** (keep private — CloudFront will access via OAC)
5. Create bucket

### 2. Create ACM certificate

1. Go to **ACM → us-east-1 region** (must be us-east-1 for CloudFront)
2. Request certificate → Public → Domain: `boot.pi2s3.com` → DNS validation
3. Click the certificate → expand domain → copy the CNAME name and value
4. In Cloudflare: add that CNAME record (proxy **OFF**)
5. Wait ~2 min — certificate status changes to **Issued**

### 3. Create CloudFront distribution

1. Go to CloudFront → **Create distribution**
2. Origin domain: pick `boot.pi2s3.com` (your S3 bucket) — **do not use the website endpoint**
3. Origin access: **Origin access control settings** → Create new OAC (sign requests)
4. Copy the S3 bucket policy that CloudFront shows you → paste it into the bucket's **Permissions → Bucket policy**
5. Viewer protocol policy: **HTTP and HTTPS** (plain HTTP is required for Pi 5 boot)
6. Compress objects: **No** (boot files are binary — compression will corrupt them)
7. Alternate domain names (CNAMEs): `boot.pi2s3.com`
8. Custom SSL certificate: select the ACM cert you just created
9. Default TTL: `300` (5 min)
10. Create distribution — takes ~10 min to deploy

### 4. Add DNS CNAME in Cloudflare

Once CloudFront shows **Deployed**:
1. Copy the CloudFront domain name (e.g. `xxxx.cloudfront.net`)
2. In Cloudflare: add CNAME `boot` → `xxxx.cloudfront.net`, proxy **OFF**

### 5. Create IAM user for CI

1. IAM → Users → **Create user**: `pi2s3-netboot-ci`
2. Attach inline policy:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::boot.pi2s3.com/*"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": "arn:aws:s3:::boot.pi2s3.com"
    }
  ]
}
```
3. Create access key → save to GitHub Secrets (see above)

### 6. Test

```bash
# Upload boot files
bash ~/pi2s3/extras/build-netboot-image.sh --upload s3://boot.pi2s3.com/

# Verify
curl -I http://boot.pi2s3.com/config.txt   # 200 OK

# Configure a Pi
bash ~/pi2s3/extras/setup-netboot.sh
```
