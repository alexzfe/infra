output "server_ipv4" {
  value = module.server.ipv4
}

output "tunnel_id" {
  value = module.tunnel.tunnel_id
}

# Ansible reads this into cloudflared's environment: `terraform output -raw tunnel_token`.
output "tunnel_token" {
  value     = module.tunnel.token
  sensitive = true
}
