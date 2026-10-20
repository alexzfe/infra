# The only Hetzner-specific code. Moving providers means replacing this module; everything else stays.
terraform {
  required_providers {
    hcloud = {
      source = "hetznercloud/hcloud"
    }
  }
}

variable "name" {
  type = string
}

variable "server_type" {
  type = string
}

variable "location" {
  type = string
}

variable "tailscale_auth_key" {
  type      = string
  sensitive = true
}

# No rules = every inbound port closed. Web traffic arrives through the Cloudflare Tunnel and admin
# traffic through Tailscale; both are outbound connections from the server.
resource "hcloud_firewall" "this" {
  name = "${var.name}-deny-inbound"
}

resource "hcloud_server" "this" {
  name         = var.name
  server_type  = var.server_type
  location     = var.location
  image        = "ubuntu-24.04"
  firewall_ids = [hcloud_firewall.this.id]

  # IPv4 stays on: ghcr.io has no IPv6, so an IPv6-only box couldn't pull images.
  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    hostname           = var.name
    tailscale_auth_key = var.tailscale_auth_key
  })

  labels = {
    managed_by = "terraform"
  }

  lifecycle {
    # The auth key is single-use and expires; a new one must not replace a running server.
    ignore_changes = [user_data, image]
  }
}

output "ipv4" {
  value = hcloud_server.this.ipv4_address
}
