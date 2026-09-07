# cloudflare

The Cloudflare side of both hosts, as Terraform: one tunnel per host, a
hostname per service under `lz-co.xyz`, and a Zero Trust Access application
in front of each hostname. Neither host opens a port for any of this:
`cloudflared` on the host dials out to Cloudflare, Cloudflare terminates
TLS, checks the policy, and forwards through the tunnel.

## What it makes

```
                 Cloudflare edge (TLS, Access policy)
                 ------------------------------------
  browser ---->  app.lz-co.xyz      -->  tunnel "trading-host"  --> 127.0.0.1:8080  control (UI + API)
                 metrics.lz-co.xyz  -->        "                --> 127.0.0.1:9100  node-exporter
  psql/ctl --->  db.lz-co.xyz       -->  tunnel "db-host"       --> 127.0.0.1:5432  postgres      (tcp)
                 ch.lz-co.xyz       -->        "                --> 127.0.0.1:9000  clickhouse     (tcp)
                 chdb.lz-co.xyz     -->        "                --> 127.0.0.1:8123  clickhouse http
                 scraper.lz-co.xyz  -->        "                --> 127.0.0.1:8084  scraper api
                 metrics-db.lz-co.xyz ->       "                --> 127.0.0.1:9100  node-exporter
```

| resource | count | why |
|---|---|---|
| `cloudflare_zero_trust_tunnel_cloudflared` | 2 | one per host; the secret is generated here and never leaves the state except as the token |
| `..._tunnel_cloudflared_config` | 2 | the ingress table, remote-managed: the host needs only its token, no config file |
| `cloudflare_dns_record` | 7 | one proxied **CNAME** per hostname to `<tunnel id>.cfargotunnel.com` |
| `cloudflare_zero_trust_access_policy` | 2 | "allowed people" (Allow, by email) and "machines by source address" (Bypass, by CIDR) |
| `cloudflare_zero_trust_access_application` | 7 | one per hostname, both policies attached, bypass first |

**CNAME to the tunnel, no A record of the host anywhere.** A tunnel is
not a pointer to the host's address. `cloudflared` on the host opens an
outbound connection to Cloudflare and identifies itself by tunnel id; the
public hostname is a proxied CNAME to `<tunnel id>.cfargotunnel.com`, so
DNS returns Cloudflare's own anycast addresses; the ingress table then maps
the hostname to a service INSIDE the host (`tcp://127.0.0.1:5432`), reached
over that connection. The host's IP is used by nothing in this chain, which
is why the security group can admit SSH only and why the trading host's
three elastic IPs are irrelevant here. A DNS record cannot carry a port
either, so `db.db.lz-co.xyz -> db.lz-co.xyz:5432` is not a shape DNS or
the tunnel has; the port lives in the ingress rule.

If you want names for the hosts themselves, for `ssh trading-host.lz-co.xyz`,
`host_a_records` adds plain unproxied A records. They serve SSH and nothing
else, and they publish the addresses, so they are off by default.

**Access, the allow-list model.** Every hostname is an Access application.
A request from a `bypass_cidrs` address (the trading host's elastic IPs, so
control and db-proxy reach the database; the dev box) is answered without
a login. Anyone else gets Cloudflare's login page and must be in
`allowed_emails`; the default login method on a new Zero Trust account is a
one-time PIN mailed to that address, valid for `session_duration` (24h).
TCP hostnames (`db.`, `ch.`) work the same way through `cloudflared access
tcp` on the client, which is what the trading host's `db-proxy` runs.

**IPv4 and IPv6 in the bypass list.** The rule matches the address
Cloudflare sees the connection come from. A dual-stack machine prefers
IPv6 for the edge, so a rule listing only its IPv4 fails for it (this is
the "had to add both" you ran into). Measured on the dev box: `curl` from
the shell arrives as `2a01:4f8:c2c:d113::1`, the same `curl` inside a
docker container as `78.47.39.128`, because docker networks are IPv4-only
unless enabled. So: list the dev box's IPv6 `/64` as well as its two IPv4
addresses; the trading host needs only its elastic IPs, since the VPC has
no IPv6 block and nothing on it can speak IPv6 to the outside; the
containers on the database host (scraper, fluentd) are IPv4-only too. Both
families are accepted in the same `ip` rule, one CIDR each.

## The process

### 0. Once, in the dashboard

1. The domain is on Cloudflare (nameservers moved), the zone is active.
2. Zero Trust is enabled for the account (Zero Trust in the left menu, pick
   a team name, the free plan covers this). Check Settings, Authentication:
   "One-time PIN" is on.
3. An API token for Terraform, My Profile, API Tokens, Create Token,
   Custom, with these permissions:
   - Account: **Cloudflare Tunnel: Edit**, **Access: Apps and Policies: Edit**
   - Zone (this zone): **DNS: Edit**, **Zone: Read**
   Copy the token once; it goes into your shell, not into any file here:
   ```bash
   export CLOUDFLARE_API_TOKEN=...      # add to ~/.zshrc if you like
   ```
4. Account id and zone id from the zone's Overview page.

### 1. Apply

```bash
cp terraform.tfvars.example terraform.tfvars   # ids, domain, your email
just init
just plan          # 2 tunnels, 2 configs, 7 CNAMEs, 2 policies, 7 apps
just apply
just hostnames
```

`bypass_cidrs` can start empty: fill in the trading host's elastic IPs
after `../trading-host` exists and apply again; the policy updates in
place.

### 2. Give each host its token

```bash
just app-token     # -> CLOUDFLARE_TUNNEL_TOKEN in trading-bots/.env,  COMPOSE_PROFILES includes tunnel
just db-token      # -> CLOUDFLARE_TUNNEL_TOKEN in trading-bots-db/.env, likewise
```

Both stacks run `cloudflared` from that token (`tunnel run`, no config
file); the ingress table is the one applied here, changed here. A hostname
answers 502 until its origin is up, 404 for a hostname the tunnel does not
know, and the Access login page before either.

### 3. Use it

- Browser: `https://app.lz-co.xyz`, log in once a day.
- Database from the laptop: `just tcp db 15432`, then
  `psql -h 127.0.0.1 -p 15432 -U trading-bots trading_bots` (the tunnel
  client logs you in through the browser the first time). Same for `ch`
  with port 9000.
- From the trading host nothing is needed: its addresses bypass the login,
  and `DATABASE_URL` points at `db-proxy`, which runs `cloudflared access
  tcp --hostname db.lz-co.xyz`.

## Day 2

- **Add a hostname:** add a label => origin to `app_ingress` or
  `db_ingress` in `terraform.tfvars`, `just apply`. CNAME, ingress rule and
  Access app appear together; the host needs no change.
- **Add a person:** `allowed_emails`, apply. **Remove one:** same; their
  session ends at the next check.
- **Rotate a tunnel:** `terraform taint 'random_bytes.tunnel_secret["db"]'`,
  apply, give the host the new token, restart cloudflared there.
- **Provider version.** This is the Cloudflare provider v5 (the current
  major): resource names carry the `zero_trust_` prefix and nested blocks
  are attributes. Do not mix in v4 examples from the web.
