terraform {
  required_version = ">= 1.10"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.52"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
    tailscale = {
      source  = "tailscale/tailscale"
      version = ">= 0.21"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # State lives in Cloudflare R2. Settings are in backend.hcl: `terraform init -backend-config=backend.hcl`.
  backend "s3" {}
}

# Credentials come from the environment, never from files:
#   HCLOUD_TOKEN, CLOUDFLARE_API_TOKEN, TAILSCALE_OAUTH_CLIENT_ID, TAILSCALE_OAUTH_CLIENT_SECRET,
#   and AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY holding the R2 key for the backend.
provider "hcloud" {}
provider "cloudflare" {}
provider "tailscale" {}
