output "hostnames" {
  description = "Every hostname, which host's tunnel it rides, and its origin there."
  value = {
    for k, h in local.hostnames : h.fqdn => { tunnel = local.hosts[h.tunnel].name, origin = h.origin }
  }
}

output "domain" {
  value = var.domain
}

output "tunnel_ids" {
  value = { for k, t in cloudflare_zero_trust_tunnel_cloudflared.host : local.hosts[k].name => t.id }
}

# Sensitive: shown only with `terraform output -raw app_tunnel_token` (just app-token).
output "app_tunnel_token" {
  description = "CLOUDFLARE_TUNNEL_TOKEN for the trading host's .env"
  value       = data.cloudflare_zero_trust_tunnel_cloudflared_token.host["app"].token
  sensitive   = true
}

output "db_tunnel_token" {
  description = "CLOUDFLARE_TUNNEL_TOKEN for the database host's .env"
  value       = data.cloudflare_zero_trust_tunnel_cloudflared_token.host["db"].token
  sensitive   = true
}

output "access_policies" {
  value = {
    allow_people    = cloudflare_zero_trust_access_policy.allow_people.id
    bypass_machines = try(cloudflare_zero_trust_access_policy.bypass_machines[0].id, "none (bypass_cidrs empty)")
  }
}
