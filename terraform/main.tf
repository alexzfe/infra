locals {
  sites     = yamldecode(file("${path.module}/../sites.yml"))
  hostnames = flatten([for app in local.sites.apps : values(app.hosts)])
  # Apps with `edge_cache: true`: every host, plus the path to leave uncached so health checks reach the origin.
  edge_cached = [for app in local.sites.apps : app if try(app.edge_cache, false)]
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

# Cache rules, zone-wide. Cloudflare caches HTML only when a rule says so; without one, every page view of a static
# site goes through the tunnel to the VPS (~0.3-0.8 s extra). Edge TTL overrides the origin's headers, so the
# browser still gets the origin's Cache-Control (e.g. `no-cache`: revalidate against the edge, which is fast).
# Deploys purge the hostname (deploy-app.yml `purge_cache`), so the TTL only bounds staleness if a purge fails.
# A zone has one ruleset per phase: if a cache rule was ever made in the dashboard, import that ruleset first.
resource "cloudflare_ruleset" "cache" {
  count = length(local.edge_cached) > 0 ? 1 : 0

  zone_id     = var.cloudflare_zone_id
  name        = "Cache rules"
  description = "Edge caching for apps with edge_cache in sites.yml"
  kind        = "zone"
  phase       = "http_request_cache_settings"

  rules = [for app in local.edge_cached : {
    ref         = "edge_cache_${app.name}"
    description = "${app.name}: cache everything at the edge except ${app.health_path}"
    expression = format(
      "(http.host in {%s} and http.request.uri.path ne \"%s\")",
      join(" ", [for host in values(app.hosts) : "\"${host}\""]),
      app.health_path,
    )
    action = "set_cache_settings"
    action_parameters = {
      cache       = true
      edge_ttl    = { mode = "override_origin", default = 604800 } # 7 days
      browser_ttl = { mode = "respect_origin" }
    }
  }]
}
