terraform {
  required_providers {
    cloudflare = {
      source = "cloudflare/cloudflare"
    }
    random = {
      source = "hashicorp/random"
    }
  }
}

variable "name" {
  type = string
}

variable "account_id" {
  type = string
}

variable "zone_id" {
  type = string
}

variable "hostnames" {
  description = "Public hostnames routed through the tunnel."
  type        = list(string)
}

variable "origin" {
  description = "Where cloudflared sends every request; the edge proxy (nginx) routes by Host from there."
  type        = string
}

resource "random_bytes" "tunnel_secret" {
  length = 32
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "this" {
  account_id    = var.account_id
  name          = var.name
  config_src    = "cloudflare"
  tunnel_secret = random_bytes.tunnel_secret.base64
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "this" {
  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.this.id

  config = {
    ingress = concat(
      [for host in var.hostnames : { hostname = host, service = var.origin }],
      [{ service = "http_status:404" }],
    )
  }
}

# Proxied (orange cloud) CNAMEs to the tunnel. These explicit records win over the home wildcard.
resource "cloudflare_dns_record" "site" {
  for_each = toset(var.hostnames)

  zone_id = var.zone_id
  name    = each.value
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.this.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
}

data "cloudflare_zero_trust_tunnel_cloudflared_token" "this" {
  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.this.id
}

output "tunnel_id" {
  value = cloudflare_zero_trust_tunnel_cloudflared.this.id
}

output "token" {
  value     = data.cloudflare_zero_trust_tunnel_cloudflared_token.this.token
  sensitive = true
}
