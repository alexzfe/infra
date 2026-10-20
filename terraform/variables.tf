variable "cloudflare_account_id" {
  description = "Cloudflare account that owns the tunnel."
  type        = string
}

variable "cloudflare_zone_id" {
  description = "Zone ID of xlobax.com."
  type        = string
}

variable "server_name" {
  description = "Server name at Hetzner, and its Tailscale hostname."
  type        = string
  default     = "xlobax-vps"
}

variable "server_type" {
  type    = string
  default = "cx23"
}

variable "location" {
  description = "Hetzner location: nbg1 (Nuremberg), fsn1 (Falkenstein) or hel1 (Helsinki)."
  type        = string
  default     = "nbg1"
}
