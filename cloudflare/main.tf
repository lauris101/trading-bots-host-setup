# Cloudflare side of the two hosts: one tunnel each, a hostname per service
# as a CNAME to the tunnel, and a Zero Trust Access application per hostname
# so nothing answers before Cloudflare has checked who is asking. No origin
# port is ever open on either host: cloudflared dials out, Cloudflare
# terminates TLS and applies the policy, the tunnel carries what is left.

locals {
  hosts = {
    app = { name = "trading-host", ingress = var.app_ingress }
    db  = { name = "db-host", ingress = var.db_ingress }
  }
  # Flatten (tunnel, label) => origin for the per-hostname resources.
  hostnames = merge([
    for key, h in local.hosts : {
      for label, origin in h.ingress :
      "${key}/${label}" => { tunnel = key, label = label, fqdn = "${label}.${var.domain}", origin = origin }
    }
  ]...)
}

# --- tunnels -----------------------------------------------------------------

resource "random_bytes" "tunnel_secret" {
  for_each = local.hosts
  length   = 32
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "host" {
  for_each = local.hosts

  account_id    = var.account_id
  name          = each.value.name
  tunnel_secret = random_bytes.tunnel_secret[each.key].base64
  # Ingress rules live here (below), not in a config file on the host: the
  # host only needs its token.
  config_src = "cloudflare"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "host" {
  for_each = local.hosts

  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.host[each.key].id

  config = {
    ingress = concat(
      [
        for label, origin in each.value.ingress : {
          hostname = "${label}.${var.domain}"
          service  = origin
        }
      ],
      # Anything else that reaches the tunnel gets a 404, not a service.
      [{ service = "http_status:404" }]
    )
  }
}

# The token each host puts in its .env as CLOUDFLARE_TUNNEL_TOKEN.
data "cloudflare_zero_trust_tunnel_cloudflared_token" "host" {
  for_each = local.hosts

  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.host[each.key].id
}

# --- DNS ---------------------------------------------------------------------

# A tunnel hostname is a proxied CNAME to <tunnel id>.cfargotunnel.com, not
# an A record: there is no origin IP to publish, which is the point.
resource "cloudflare_dns_record" "hostname" {
  for_each = local.hostnames

  zone_id = var.zone_id
  name    = each.value.fqdn
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.host[each.value.tunnel].id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "tunnel ${local.hosts[each.value.tunnel].name}: ${each.value.origin} (terraform, trading-bots-host-setup)"
}

# Optional convenience names for SSH (host_a_records). Grey-cloud: DNS only,
# no proxy, because SSH is not HTTP and Cloudflare would not carry it.
resource "cloudflare_dns_record" "host_a" {
  for_each = var.host_a_records

  zone_id = var.zone_id
  name    = "${each.key}.${var.domain}"
  type    = "A"
  content = each.value
  proxied = false
  ttl     = 300
  comment = "ssh name for the host itself (terraform, trading-bots-host-setup)"
}

# --- Access ------------------------------------------------------------------

# Reusable policies: who may log in, and which machines skip the login.
resource "cloudflare_zero_trust_access_policy" "allow_people" {
  account_id = var.account_id
  name       = "trading-bots: allowed people"
  decision   = "allow"
  include = [
    for e in var.allowed_emails : { email = { email = e } }
  ]
}

resource "cloudflare_zero_trust_access_policy" "bypass_machines" {
  count = length(var.bypass_cidrs) > 0 ? 1 : 0

  account_id = var.account_id
  name       = "trading-bots: machines by source address"
  decision   = "bypass"
  include = [
    for c in var.bypass_cidrs : { ip = { ip = c } }
  ]
}

# One application per host, covering every hostname on that host's tunnel.
# All of a host's hostnames share the two policies and one login session.
# TCP services (postgres, clickhouse native) are covered the same way:
# `cloudflared access tcp` on the client does the login (or is let through
# by the bypass rule) and forwards the port.
resource "cloudflare_zero_trust_access_application" "host" {
  for_each = local.hosts

  account_id = var.account_id
  name       = each.value.name
  type       = "self_hosted"
  domain     = "${sort(keys(each.value.ingress))[0]}.${var.domain}"
  destinations = [
    for label in sort(keys(each.value.ingress)) : { type = "public", uri = "${label}.${var.domain}" }
  ]
  session_duration = var.session_duration
  # Machines first: a source address on the bypass list is answered without
  # a login page; everyone else is asked to log in.
  policies = concat(
    [for p in cloudflare_zero_trust_access_policy.bypass_machines : { id = p.id, precedence = 1 }],
    [{ id = cloudflare_zero_trust_access_policy.allow_people.id, precedence = 2 }]
  )
  auto_redirect_to_identity  = false
  app_launcher_visible       = true
  http_only_cookie_attribute = true
}
