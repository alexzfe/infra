locals {
  sites     = yamldecode(file("${path.module}/../sites.yml"))
  hostnames = flatten([for app in local.sites.apps : values(app.hosts)])
}

# Single-use key the server joins the tailnet with on first boot.
resource "tailscale_tailnet_key" "server" {
  reusable      = false
  ephemeral     = false
  preauthorized = true
  expiry        = 3600
  tags          = ["tag:server"]
  description   = "${var.server_name} bootstrap"
}

module "server" {
  source = "./modules/hetzner-server"

  name               = var.server_name
  server_type        = var.server_type
  location           = var.location
  tailscale_auth_key = tailscale_tailnet_key.server.key
}

module "tunnel" {
  source = "./modules/cloudflare-tunnel"

  name       = var.server_name
  account_id = var.cloudflare_account_id
  zone_id    = var.cloudflare_zone_id
  hostnames  = local.hostnames
  origin     = "http://proxy:80"
}

# HSTS, zone-wide. Cloudflare adds the header only to traffic it proxies, which is every hostname in sites.yml and
# all of it https. No includeSubDomains: the home `*.xlobax.com` wildcard is DNS-only, straight to the homeserver,
# and anything there without a certificate would become unreachable in browsers that had seen the header.
resource "cloudflare_zone_setting" "hsts" {
  zone_id    = var.cloudflare_zone_id
  setting_id = "security_header"
  value = {
    strict_transport_security = {
      enabled            = true
      max_age            = 15552000 # 180 days
      include_subdomains = false
      preload            = false
      nosniff            = false # this resource only means to turn on HSTS
    }
  }
}
