# trading-bots-host-setup

The infrastructure under the trading-bots stacks, as code, in three
independent parts. Each has its own README, `justfile` and state; run
`just` from inside the part's directory.

| part | tool | makes |
|---|---|---|
| [`trading-host/`](trading-host/README.md) | terraform + ansible | the AWS Graviton box in Tokyo: VPC, `c7g.2xlarge` on Debian 13, 80 GB root, 3 elastic IPs, SSH-only security group; then the OS: `trading-bot` account, Docker, CrowdSec, secondary IPs, core isolation |
| [`db-host/`](db-host/README.md) | ansible | a rented Debian VPS handed over as root + password, turned into the same keys-only `trading-bot` + Docker + CrowdSec box, with a swapfile |
| [`cloudflare/`](cloudflare/README.md) | terraform | one tunnel per host, the hostnames under `lz-co.xyz` as CNAMEs to the tunnels, a Zero Trust Access application per host (people by email, machines by source address) |
| `ansible/roles/` | shared | the roles both playbooks use: `base`, `sshd`, `trading_bot_user`, `docker`, `crowdsec`, `secondary_ips`, `hotpath`, `swapfile` |

The services (postgres, ClickHouse, the bot, control, the scraper,
fluentd) are deployed from the `trading-bots` and `trading-bots-db`
repositories, as the `trading-bot` user each part creates.

The services host (an existing Hetzner box: Uptime Kuma, Grafana, its own
DNS) is outside this repository except for one thing: its addresses are on
the Access bypass list (`bypass_cidrs` in `cloudflare/terraform.tfvars`) so
its monitors reach the hostnames without a login.

## Order

```
1. trading-host   just init/plan/apply, just provision      -> 3 elastic IPs, a ready box
2. db-host        just bootstrap                             -> a ready box
3. cloudflare     just init/plan/apply (bypass_cidrs = the 3 EIPs, the services host, the dev box)
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

## Terraform state: in R2, and how to restore

Both terraform parts keep their state in one private Cloudflare R2 bucket
through the S3 backend, at `trading-host/terraform.tfstate` and
`cloudflare/terraform.tfstate`. No state file is on the laptop. The state
holds secrets (the tunnel tokens), so the bucket stays private and the
token that reads it is scoped to the bucket.

Setup, once:

1. R2, Create bucket `trading-bots-tfstate` (any region; leave it private).
2. R2, Manage API tokens, Create: Object Read & Write, this bucket only.
   Note the access key id, secret access key and the account's S3 endpoint.
3. `cp backend.hcl.example backend.hcl` at the repo root and fill in the
   bucket, endpoint and the two keys. Store the same three values in your
   password manager: they are the restore.
4. `just init` in each part connects it to the bucket.

Restore on a new laptop, or after the checkout is lost:

```bash
git clone git@github.com:lauris101/trading-bots-host-setup.git && cd trading-bots-host-setup
# backend.hcl from the password manager; terraform.tfvars / vars.yml likewise (or re-create them)
cd trading-host && just tools && just init && just plan     # plan shows "No changes"
just inventory                                              # inventory back from the state
cd ../cloudflare && just init && just plan && just app-token
```

`just init` downloads the state from the bucket; everything Terraform
manages is known again, including the tunnel tokens and the elastic IPs.
The two `terraform.tfvars` files are not state: they are re-created from the
examples with the same values (SSH key, account and zone ids, emails,
bypass list). A plan that shows changes after a restore means a tfvars
value differs from what was applied.

R2 does not version objects. `just apply` and `just destroy` first run
`just state-backup`, which writes a dated copy of the current state to
`~/tfstate-backups/` (the last 30 per part are kept; a first apply with no
state skips it). To go back to a copy: `terraform state push <file>`.

If a state file is lost with no copy, the resources still exist and are
re-adopted with `terraform import`, one per resource, by id (tags
`project=trading-bots` and the tunnel names find them). The READMEs of the
parts list the import forms.

Locking: the backend runs without a lock file. One operator applies at a
time; two concurrent applies from two machines would race.

## Security model

Each host has one inbound port, SSH, open to the internet (the operator has
no fixed address); sshd accepts keys only for named users; CrowdSec with the
nftables bouncer drops brute-forcers and the community blocklist. The UI,
API, databases and metrics are reached through Cloudflare tunnels behind
Access: listed people log in with a one-time PIN, listed machine addresses
pass without a login. The trading key is placed on the trading host by hand
and is in no repository.
