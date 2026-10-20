# Cloudflare R2 as an S3 backend. Fill in your Cloudflare account ID (it isn't a secret).
bucket   = "xlobax-tfstate"
key      = "infra/terraform.tfstate"
region   = "auto"
endpoints = {
  s3 = "https://f734728e6498a634a528ec599073404b.r2.cloudflarestorage.com"
}

# R2 isn't AWS: skip the AWS-only checks.
skip_credentials_validation = true
skip_region_validation      = true
skip_requesting_account_id  = true
skip_metadata_api_check     = true
skip_s3_checksum            = true
use_path_style              = true

# Native S3 locking (a .tflock object), so CI and your laptop can't apply at the same time.
use_lockfile = true
