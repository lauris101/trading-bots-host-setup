# db-host

The database host, as code: a rented VPS (Debian 12 or 13) delivered as
`root` with a password, configured as a keys-only host with the
`trading-bot` account, Docker, CrowdSec and a swapfile, for the
`trading-bots-db` stack. Ansible only.

## The process

```
laptop                                   the VPS
------                                   -------
0. provider console: order Debian 13,    root + password arrive by mail / console
   note the IP
1. just bootstrap  --ansible, as root-->  base, trading-bot user + your key, sshd keys-only
   (asks the root password once)         (root login is over), docker, crowdsec, swapfile
2. just provision  --as trading-bot--->   the same, idempotent, from now on
3. ssh trading-bot@IP                     clone trading-bots-db, bootstrap.sh, fill .env, deploy.sh
```

### 0. Tools

`just tools` installs Ansible and the two collections (Homebrew on macOS,
apt and pipx on Debian). SSH key: the same key as the trading host.

### 1. Bootstrap

```bash
cp inventory.yml.example inventory.yml   # the VPS's address and the private key file
cp vars.yml.example vars.yml             # your public key, whitelist, swap size
just bootstrap                           # SSH password: the one the provider gave root
```

`ansible_ssh_private_key_file` in the inventory must be the private half of
`trading_bot_public_key` in `vars.yml`; every run after bootstrap logs in
with it.

The play runs as root once. Role order in `playbook.yml`: `trading_bot_user`
installs the key before `sshd` disables passwords and removes root from
`AllowUsers`. If the play fails between the two, root still logs in; re-run.
Afterwards `just ping` verifies the key login as `trading-bot`; then discard
the root password.

Provider drop-ins that allow passwords are commented out by the `sshd`
role; root is not in `AllowUsers`.

### 2. Provision

`just provision` from then on, as `trading-bot` with the key and sudo. All
roles are idempotent; `just check` shows what would change, `just tags
crowdsec` runs one role.

Roles, in order:

| role | does |
|---|---|
| `base` | hostname, UTC, packages (`git just jq curl zstd chrony unattended-upgrades ...`), chrony from the pool (no Amazon link-local source here), security updates without automatic reboots, bounded journald |
| `trading_bot_user` | the account, its one authorized key, sudoers, `/data/trading-bots` and `/logs/trading-bots` owned by it |
| `sshd` | keys only, no root, `AllowUsers trading-bot`, tight `MaxStartups`; disables image drop-ins that allow passwords |
| `docker` | Docker Engine + buildx + compose plugin from download.docker.com (this host's architecture), `trading-bot` in the docker group |
| `crowdsec` | CrowdSec + nftables bouncer for the open port 22 (see the trading-host README for how it behaves and the `cscli` commands) |
| `swapfile` | a 2 GB swapfile (`swapfile_gb`), swappiness 10: a margin against the OOM killer on a 4 GB box, not memory |

The play ends by listing what listens beyond loopback; before the stack
runs, that is sshd. The stack binds postgres and ClickHouse to
`POSTGRES_BIND`/`CLICKHOUSE_BIND` (loopback or the docker bridge) and they
are reached through the Cloudflare tunnel. A provider firewall, if any, can
admit port 22 only. The play installs no host firewall; check `ss -ltn`
after the first deploy.

### 3. Hand-over to trading-bots-db

The play generated a GitHub deploy key for the `trading-bot` account and
printed its public half in the summary (`just deploy-key` prints it again).
Add it to the `trading-bots-db` repository as a read-only deploy key
(Settings, Deploy keys), then, as `trading-bot` on the box (`just ssh`):

```bash
git clone git@github.com:lauris101/trading-bots-db.git && cd trading-bots-db
scripts/bootstrap.sh                 # generates .env with random passwords, stops
$EDITOR .env                         # R2 backend for wal-g, CLOUDFLARE_TUNNEL_TOKEN (../cloudflare),
                                     # IMAGES_S3_BUCKET for the scraper image, POSTGRES_BIND/CLICKHOUSE_BIND
scripts/bootstrap.sh                 # deploys: postgres, clickhouse, fluentd, scheduler, node-exporter, cloudflared
```

The tunnel token comes from the `cloudflare` part of this repository
(`just db-token` there). The database is then reachable as
`db.<domain>` (postgres), `ch.<domain>` (ClickHouse native), `chdb.<domain>`
(ClickHouse HTTP) for the trading host and for you.

## Sizing

2 vCPU / 4 GB with the swapfile; ClickHouse is capped in the compose file.
Disk holds postgres data, ClickHouse quotes (1 day TTL) and 7 days of logs;
wal-g backups go to R2. 40 GB to start.
