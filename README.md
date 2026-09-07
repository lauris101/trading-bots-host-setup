# trading-bots-host-setup

The infrastructure under the trading-bots stacks, as code, in three
independent parts. Each has its own README, `justfile` and state; run
`just` from inside the part's directory.

| part | tool | makes |
|---|---|---|
| [`trading-host/`](trading-host/README.md) | terraform + ansible | the AWS Graviton box in Tokyo: VPC, `c7g.2xlarge` on Debian 13, 80 GB root, 3 elastic IPs, SSH-only security group; then the OS: `trading-bot` account, Docker, CrowdSec, secondary IPs, core isolation |
| [`db-host/`](db-host/README.md) | ansible | a rented Debian VPS handed over as root + password, turned into the same keys-only `trading-bot` + Docker + CrowdSec box, with a swapfile |
| [`cloudflare/`](cloudflare/README.md) | terraform | one tunnel per host, the hostnames under `lz-co.xyz` as CNAMEs to the tunnels, a Zero Trust Access application per hostname (people by email, machines by source address) |
| `ansible/roles/` | shared | the roles both playbooks use: `base`, `sshd`, `trading_bot_user`, `docker`, `crowdsec`, `secondary_ips`, `hotpath`, `swapfile` |

The services (postgres, ClickHouse, the bot, control, the scraper,
fluentd) are deployed from the `trading-bots` and `trading-bots-db`
repositories, as the `trading-bot` user each part creates.

## Order

```
1. trading-host   just init/plan/apply, just provision      -> 3 elastic IPs, a ready box
2. db-host        just bootstrap                             -> a ready box
3. cloudflare     just init/plan/apply (bypass_cidrs = the 3 EIPs + dev box)
                  just app-token / just db-token             -> CLOUDFLARE_TUNNEL_TOKEN for each .env
4. on db-host     trading-bots-db: bootstrap.sh, .env (token, R2), deploy    -> db./ch./chdb.<domain>
5. on trading-host trading-bots: bootstrap.sh, .env (token, DATABASE_URL via db-proxy), deploy.sh prod vX.Y.Z
```

1 and 2 are independent of each other. 3 wants the trading host's elastic
IPs for the machine bypass rule but can start without them. 4 before 5,
because the trading stack checks the database at deploy.

## Tools, once (Mac)

```bash
brew install just git
brew install hashicorp/tap/terraform ansible awscli cloudflared
git clone git@github.com:lauris101/trading-bots-host-setup.git && cd trading-bots-host-setup
ansible-galaxy collection install -r ansible/requirements.yml
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_trading -C "trading-host"   # the one key for both hosts
```

(`just tools` in `trading-host/` or `db-host/` does the same install.)
Credentials: an IAM user for AWS (`trading-host/iam/`), a scoped API
token for Cloudflare (`cloudflare/README.md`); both live in your shell or
`~/.aws`, never in this repository. All `terraform.tfvars`, `vars.yml`,
inventories and state files are gitignored.

## Security model

Each host has one inbound port, SSH, open to the internet (the operator has
no fixed address); sshd accepts keys only for named users; CrowdSec with the
nftables bouncer drops brute-forcers and the community blocklist. The UI,
API, databases and metrics are reached through Cloudflare tunnels behind
Access: listed people log in with a one-time PIN, listed machine addresses
pass without a login. The trading key is placed on the trading host by hand
and is in no repository.
