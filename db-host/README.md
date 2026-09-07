# db-host

The database host, as code: a rented VPS (any provider with a Debian 12 or
13 image) that you are handed as `root` with a password, turned into a
keys-only box with the `trading-bot` account, Docker, CrowdSec and a
swapfile, ready for the `trading-bots-db` stack. Ansible only; there is no
cloud API to drive here.

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

Same as the trading host: `just tools` here installs Ansible and the two
collections (Homebrew on a Mac). The SSH key is the one you made for the
trading host; there is no reason for a second.

### 1. Bootstrap

```bash
cp inventory.yml.example inventory.yml   # the VPS's address
cp vars.yml.example vars.yml             # your key, whitelist, swap size
just bootstrap                           # SSH password: the one the provider gave root
```

The play runs as root exactly once. Order matters and is fixed in
`playbook.yml`: the `trading_bot_user` role installs your key **before**
the `sshd` role turns off passwords and removes root from `AllowUsers`.
Should the play fail between the two, root still works: fix and re-run.
When it finishes, `just ping` proves the key login as `trading-bot`; only
then throw the root password away.

If the provider's image runs sshd with a `PermitRootLogin yes` drop-in of
its own, the `sshd` role comments it out (it disables any drop-in that
still allows passwords) and reloads; root is then key-only and not in
`AllowUsers`, so effectively closed.

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

The play ends by listing what listens beyond loopback: until the stack
runs, that is sshd alone. The stack itself binds postgres and ClickHouse to
`POSTGRES_BIND`/`CLICKHOUSE_BIND` (loopback or the docker bridge, never
`0.0.0.0`), and everything reaches them through the Cloudflare tunnel, so
the provider firewall, if there is one, can be "22 only" too. There is no
host firewall in the play (docker and a second rule set fight), which is
why the binds matter: check `ss -ltn` after the first deploy.

### 3. Hand-over to trading-bots-db

As `trading-bot` on the box (`just ssh`):

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

The stack runs on 2 vCPU / 4 GB with the swapfile as margin; ClickHouse is
the hungry one and is capped in the compose file. Disk is the constraint to
watch: postgres data, ClickHouse quotes (1 day TTL), 7 days of logs, wal-g
sends backups off-box to R2. 40 GB is comfortable to start.
