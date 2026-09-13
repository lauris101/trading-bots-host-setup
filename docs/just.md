# `just` recipes

Three justfiles, one per directory; run each from its directory. `just
--list` there prints the names with their one-line comments. Terraform
recipes read the state backend from `../backend.hcl`; ansible recipes read
the inventory next to them.

## `cloudflare/` (terraform: tunnels, DNS, Access)

| recipe | runs | use |
| --- | --- | --- |
| `just init` | `terraform init -backend-config=../backend.hcl` | Download the providers and connect to the R2 state bucket. First, and after a provider change. |
| `just init-migrate` | `terraform init ... -migrate-state` | One time: move a local state into the bucket if `apply` ran before the backend existed. |
| `just state-backup` | `terraform state pull` to `~/tfstate-backups/cloudflare-<timestamp>.tfstate` | Copy of the current state (R2 keeps no versions), last 30 kept. Runs by itself before every apply and destroy. |
| `just plan` | `terraform fmt -recursive`, `validate`, `plan` | What would change. |
| `just apply` | `just state-backup` then `terraform apply` | Create or update tunnels, hostnames and Access applications. |
| `just hostnames` | `terraform output hostnames` | Every hostname with its tunnel and origin. |
| `just app-token` | `terraform output -raw app_tunnel_token` | The trading host's tunnel token: `CLOUDFLARE_TUNNEL_TOKEN` in trading-bots `.env`. |
| `just db-token` | `terraform output -raw db_tunnel_token` | The database host's tunnel token: `CLOUDFLARE_TUNNEL_TOKEN` in trading-bots-db `.env`. |
| `just tcp <label> <port>` | `cloudflared access tcp --hostname <label>.<domain> --url 127.0.0.1:<port>` | Log in to a TCP hostname from the laptop and forward it locally, e.g. `just tcp db 15432` then `psql -h 127.0.0.1 -p 15432`. |
| `just tunnels` | two `cloudflared access tcp` in the background: `db` on 15432, `ch` on 19000 | Forward postgres and ClickHouse's native port at once; Ctrl-C closes both. `access tcp` works only for TCP hostnames; the HTTP ones (`chdb`, `ui`, `api`) are used in a browser, or with `cloudflared access curl https://chdb.<domain>/...`. |
| `just destroy` | `just state-backup` then `terraform destroy` | Tear down tunnels, DNS names and Access apps. The hosts' cloudflared then fail to connect. |
| `just help [recipe]` | prints the matching row of this section | Explain one recipe from the directory you are in, e.g. `just help apply`; without an argument, `just --list` plus a pointer here. |

## `trading-host/` (terraform: AWS; ansible: the OS)

| recipe | runs | use |
| --- | --- | --- |
| `just tools` | brew or apt+pipx installs, `ansible-galaxy collection install` | Terraform, ansible, awscli and the collections, once per machine. |
| `just init` | `terraform init -backend-config=../backend.hcl` | Providers and the state bucket. |
| `just init-migrate` | `terraform init ... -migrate-state` | One time, local state into the bucket. |
| `just state-backup` | state pull to `~/tfstate-backups/trading-host-<timestamp>.tfstate` | As above; runs before apply, rebuild, park, unpark, destroy. |
| `just plan` | fmt, validate, plan | What would change in AWS. |
| `just apply` | state-backup, `terraform apply`, `just inventory` | Create or update the instance, elastic IPs, security group; then refresh the ansible inventory. |
| `just rebuild` | state-backup, apply with termination protection off on the instance, apply, inventory | Replace the instance (new availability zone or AMI). A fresh disk: `just provision` afterwards. |
| `just inventory` | `terraform output -raw ansible_inventory > inventory/hosts.yml` | Write the ansible inventory from the terraform outputs. |
| `just ips` | `terraform output addresses` | The elastic IPs and what each is bound to. |
| `just status` | state list and outputs | Parked or running: is an instance in the state, which elastic IPs are held. |
| `just ping` | `ansible all -m ping` | Ansible can reach the host as `admin`. |
| `just check` | `ansible-playbook playbook.yml --check --diff` | Dry run of the playbook. |
| `just provision` | `ansible-playbook playbook.yml --diff` | Configure the host: users, sshd, docker, CrowdSec, hot-path core isolation. Idempotent; reboots only when the kernel command line changed. |
| `just tags <tags>` | `ansible-playbook playbook.yml --diff --tags <tags>` | A subset of roles, e.g. `just tags trading_bot_user,sshd`. |
| `just ssh` | `ssh -i <key> admin@<host>` | Shell as ansible's user. |
| `just ssh-bot` | `ssh -i <key> trading-bot@<host>` | Shell as the account the stack runs under. |
| `just latency [samples]` | `scripts/hl-latency.sh` on the host over ssh | TCP connect latency from the host to every Hyperliquid API address; compare availability zones with it. |
| `just deploy-key` | `cat ~/.ssh/id_ed25519_github.pub` on the host via ansible | The host's GitHub deploy key (public half) to paste into the repository's Deploy keys. |
| `just park` | state-backup, termination protection off, `terraform destroy -target=aws_instance.host` | Destroy the instance only, keep the elastic IPs allocated so bypass lists and DNS keep working. No instance charge while parked; the IPs are charged. README "Park". |
| `just unpark` | state-backup, `terraform apply`, inventory | Recreate the instance on the same elastic IPs. A fresh disk: `ssh-keygen -R <ip>`, then `just provision`, then a new GitHub deploy key. |
| `just destroy` | state-backup, termination protection off, `terraform destroy` | Everything, including the elastic IPs. README "Tear down". |
| `just help [recipe]` | prints the matching row of this section | Explain one recipe from the directory you are in, e.g. `just help apply`; without an argument, `just --list` plus a pointer here. |

## `db-host/` (ansible over a rented VPS)

| recipe | runs | use |
| --- | --- | --- |
| `just tools` | brew or apt+pipx ansible, `ansible-galaxy collection install` | Ansible and the collections, once per machine. |
| `just bootstrap` | `ansible-playbook playbook.yml --diff --ask-pass -e ansible_user=root -e ansible_become=false` | First run: log in as root with the password you were given, create the trading-bot account with your key, lock sshd to keys. Root cannot log in afterwards. |
| `just provision` | `ansible-playbook playbook.yml --diff` | Every later run, as trading-bot with the key. Idempotent. |
| `just check` | `... --check --diff` | Dry run with diffs. |
| `just tags <tags>` | `... --diff --tags <tags>` | A subset of roles, e.g. `just tags crowdsec,sshd`. |
| `just ping` | `ansible all -m ping` | Prove the key login works. Run it before trusting that root is locked out. |
| `just ssh` | `ssh -i <key> trading-bot@<host>` from `inventory.yml` | Shell as the stack's account. |
| `just deploy-key` | `cat ~/.ssh/id_ed25519_github.pub` on the host via ansible | The host's GitHub deploy key (public half) for the trading-bots-db repository's Deploy keys. |
| `just help [recipe]` | prints the matching row of this section | Explain one recipe from the directory you are in, e.g. `just help apply`; without an argument, `just --list` plus a pointer here. |
