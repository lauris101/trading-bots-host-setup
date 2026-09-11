variable "cloudflare_api_token" {
  description = "API token for the Cloudflare provider (zone DNS edit, Access and tunnels edit). Null: the CLOUDFLARE_API_TOKEN environment variable."
  type        = string
  sensitive   = true
  default     = null
}

variable "account_id" {
  description = "Cloudflare account id (dashboard, any zone's Overview page, right column)."
  type        = string
}

variable "zone_id" {
  description = "Zone id of the domain (same Overview page)."
  type        = string
}

variable "domain" {
  description = "The domain the hostnames hang off."
  type        = string
  default     = "lz-co.xyz"
}

variable "allowed_emails" {
  description = "People who may open the browser-facing hostnames and log in to the TCP ones from a laptop (Access 'Allow' rule; login by one-time PIN to these addresses, or your identity provider)."
  type        = list(string)

  validation {
    condition     = length(var.allowed_emails) > 0
    error_message = "At least one email, or nobody can log in."
  }
}

variable "bypass_cidrs" {
  description = "Machines allowed through WITHOUT logging in (Access 'Bypass' rule): the trading host's elastic IPs so control/db-proxy reach the database, plus the dev box. Never a laptop on a home connection."
  type        = list(string)
  default     = []
}

# Hostnames on the trading host's tunnel. cloudflared runs with
# network_mode: host there, so origins are the host's own published ports.
variable "app_ingress" {
  description = "hostname label => origin, on the trading host's tunnel."
  type        = map(string)
  default = {
    app     = "http://127.0.0.1:8080" # control: UI at /, API alongside
    metrics = "http://127.0.0.1:9100" # node-exporter
  }
}

# Hostnames on the database host's tunnel. TCP origins are reached from a
# client with `cloudflared access tcp` (the trading host's db-proxy does
# this); HTTP ones straight from a browser or curl.
variable "db_ingress" {
  description = "hostname label => origin, on the database host's tunnel."
  type        = map(string)
  default = {
    db         = "tcp://127.0.0.1:5432"  # postgres
    ch         = "tcp://127.0.0.1:9000"  # clickhouse native protocol
    chdb       = "http://127.0.0.1:8123" # clickhouse http
    scraper    = "http://127.0.0.1:8084" # the scraper's api (control drives it)
    metrics-db = "http://127.0.0.1:9100" # node-exporter
  }
}

variable "host_a_records" {
  description = "Optional plain A records naming the hosts themselves (label => IPv4), unproxied, for `ssh trading-host.lz-co.xyz`. Not used by the tunnels, which never point at a host address; publishing these only reveals the IPs, whose one open port is SSH."
  type        = map(string)
  default     = {}
}

variable "session_duration" {
  description = "How long an Access login lasts before the next one-time PIN."
  type        = string
  default     = "24h"
}
