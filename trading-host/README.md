# trading-host

The AWS trading host, as code. Two layers, run from the laptop:

| layer | tool | makes |
|---|---|---|
| AWS resources | terraform (`terraform/`) | VPC and public subnet in Tokyo, `c7g.2xlarge` Graviton instance on Debian 13 arm64, 80 GB encrypted gp3 root volume, one network interface with 3 private addresses, 3 elastic IPs bound to them, security group admitting SSH only |
| the OS | ansible (`playbook.yml`, roles in `../ansible/roles`) | packages, UTC and Amazon time sync, sshd hardening, the `trading-bot` account (sudo, docker group), Docker Engine and compose, CrowdSec with the nftables bouncer, a unit that puts the secondary IPs on the interface, kernel core isolation and network sysctls, `/data/trading-bots` and `/logs/trading-bots` |

The trading key, the database and Cloudflare are not configured here. They
are set up afterwards from the `trading-bots` repository, as the
`trading-bot` user (section 4).

## Process

```
laptop                                     AWS (ap-northeast-1)
------                                     --------------------
1. just init / plan / apply  --terraform-->  VPC, subnet, IGW, SG(22 only), ENI(3 IPs),
                                             c7g.2xlarge Debian 13, 80 GB root, 3 EIPs
2. just inventory            <-- outputs --  first EIP + instance id -> inventory/hosts.yml
3. just provision            --ansible---->  ssh admin@EIP: base, sshd, trading-bot user,
   (reboots once, for isolcpus)              docker, crowdsec, secondary IPs, hotpath
4. ssh trading-bot@EIP                       clone trading-bots, bootstrap.sh, deploy.sh prod vX.Y.Z
```

### 0. Tools and credentials

Tools: `terraform` >= 1.6 (or OpenTofu with `tf := "tofu -chdir=terraform"`
in the justfile), `ansible-core` >= 2.15 with the `ansible.posix` and
`community.general` collections, `just`, `aws` CLI. `just tools` installs
them (Homebrew on macOS, apt and pipx on Debian) and the collections.

macOS:

```bash
brew install just git
git clone git@github.com:lauris101/trading-bots-host-setup.git && cd trading-bots-host-setup/trading-host
just tools

# the SSH key for the box (admin and trading-bot)
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_trading -C "trading-host"
cat ~/.ssh/id_ed25519_trading.pub      # -> ssh_public_key in terraform.tfvars

cat >> ~/.ssh/config <<'EOF'
Host trading-host *.compute.amazonaws.com
  IdentityFile ~/.ssh/id_ed25519_trading
  IdentitiesOnly yes
  ServerAliveInterval 30
EOF
```

After the first apply, add the first elastic IP to the `Host` line, since
the inventory addresses the host by IP. Terraform comes from the
`hashicorp/tap` formula. `brew install ansible` includes Python. If
`ansible-playbook` exits with an `objc ... fork()` error, set
`export OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES` in the shell profile.

SSH key: one public key, `ssh_public_key` in `terraform.tfvars`. Terraform
gives it to the AMI's `admin` user (Ansible's login) and writes it into the
inventory; Ansible gives the same key to `trading-bot`. A different key for
`trading-bot` is set with `trading_bot_public_key` in `vars.yml`.

#### AWS credentials

A dedicated IAM user with an access key in a named profile, and a policy
limited to EC2 in Tokyo.

1. IAM console, Users, Create user `terraform-trading`, no console access.
2. Permissions, Create inline policy, JSON, paste `iam/terraform-policy.json`
   (all `ec2:` actions in `ap-northeast-1`, read-only describes elsewhere).
3. Security credentials, Create access key, "Application running outside
   AWS". Store it:

   ```ini
   # ~/.aws/credentials
   [trading]
   aws_access_key_id     = AKIA...
   aws_secret_access_key = ...
   region                = ap-northeast-1
   ```

   or `aws configure --profile trading`.
4. `aws_profile = "trading"` in `terraform.tfvars`.

Rotate the key from the same IAM page; nothing else changes.

### 1. AWS resources

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # fill in
just init
just plan        # fmt, validate, plan (about 20 resources)
just apply       # creates them, then writes the inventory
just ips         # elastic IP -> private address
```

`terraform.tfvars`: `ssh_public_key`, `aws_profile`, and optionally
`ssh_allowed_cidrs` (default: the whole internet). Other settings have
defaults in `variables.tf`. State is in the R2 bucket (repository README,
"Terraform state"); `just init` needs `../backend.hcl`.

What is created:

- **VPC** `10.20.0.0/16` with one public subnet in `availability_zone`
  (default `ap-northeast-1a`), internet gateway, route table.
- **Security group**: inbound TCP 22 from `ssh_allowed_cidrs`; all outbound.
  No other inbound rule. No host firewall besides CrowdSec's own nftables
  table.
- **One ENI** with `elastic_ip_count` private addresses (default 3) and
  the same number of elastic IPs, bound one-to-one. AWS maps each elastic IP
  to its private address at the internet gateway (one-to-one NAT); the
  interface carries the private addresses. The bot's `aws` IP provider
  reads the mapping from the instance metadata (`ipv4-associations`), binds
  the private address and reports the elastic IP. The `secondary_ips` role
  configures the extra private addresses on the interface.
- **Instance** `c7g.2xlarge`, latest Debian 13 arm64 AMI at launch, pinned
  afterwards (`lifecycle.ignore_changes = [ami]`); IMDSv2 required, hop
  limit 2; termination protection on (`termination_protection`).
- **Root volume** 80 GB gp3, encrypted, deleted with the instance. The
  filesystem grows into it at first boot.

Availability zone: Hyperliquid runs in AWS Tokyo across several zones
behind CloudFront; zone names are account-specific. `just latency` measures
TCP connect times from the host to every API address (measured 2026-09-10,
median handshake to the `api.` edge: `1d` 1.35 ms, `1a` 1.6 ms, `1c`
slowest; the host runs in `1d`). To change the zone,
set `availability_zone` in `terraform.tfvars`, then `just rebuild` and
`just provision`: subnet, ENI and instance are replaced (the recipe lifts
termination protection on the old instance first, since a replace starts
with a terminate); the elastic IPs are kept.

### 2. Inventory

`just apply` writes `inventory/hosts.yml` from the terraform outputs
(first elastic IP, `admin` user, instance id, elastic IPs, public key);
`just inventory` regenerates it. `just ping` checks the login.

### 3. The OS

```bash
cp vars.yml.example vars.yml
just check       # dry run with diffs
just provision   # reboots once on a fresh host
```

`vars.yml`: `trading_bot_public_key` (default: the key from the inventory),
`trading_bot_sudo` (default true), `hotpath_isolated_cpus` (default `4-7`,
the cores the bot config pins its spinners to), `crowdsec_*`,
`data_base_dir`/`logs_base_dir` (prefixes, default empty, as
`DATA_BASE_DIR`/`LOGS_BASE_DIR` in the `.env`), `host_name`.

Roles, in order:

| role | does |
|---|---|
| `base` | hostname, UTC, packages (`git just jq curl zstd tmux chrony unattended-upgrades ...`), chrony on the Amazon Time Sync Service (`169.254.169.123`), security updates without automatic reboots, bounded journald |
| `sshd` | keys only, no root, `AllowUsers admin trading-bot`, `MaxAuthTries 3`, `LoginGraceTime 20`, `MaxStartups 10:50:30`, per-source limits; disables image drop-ins that allow passwords |
| `trading_bot_user` | the account, its authorized key (exclusive), sudoers entry, `${data_base_dir}/data/trading-bots` and `${logs_base_dir}/logs/trading-bots` owned by it, `~/.config/hl` (0700) for the venue key |
| `docker` | Docker Engine, buildx and compose plugin from download.docker.com (arm64), `live-restore`, `trading-bot` in the docker group |
| `crowdsec` | CrowdSec 1.8 from its repository, sshd read from the journal, `linux` and `sshd` collections, local API on `crowdsec_lapi_port` (8770), nftables bouncer (DROP, IPv6 off), whitelist `crowdsec_whitelist_cidrs`, optional console enrollment |
| `secondary_ips` | `aws-secondary-ips` script with a systemd service and 1-minute timer: reads the ENI's addresses from the metadata and adds missing ones to the interface as `/32` |
| `github_deploy_key` | an ed25519 key pair for the `trading-bot` account (generated on the host, never copied), `~/.ssh/config` pointing github.com at it, GitHub's host keys in `known_hosts`; the public half is printed by the summary and `just deploy-key` |
| `hotpath` | `isolcpus=domain,managed_irq nohz_full rcu_nocbs` for `hotpath_isolated_cpus` and `irqaffinity` for `hotpath_housekeeping_cpus` via a grub drop-in (reboot only when the line changed); irqbalance banned from the isolated cores; `bot-irq-affinity.service` pins every network queue interrupt to the housekeeping cores at boot; sysctls: 16 MB socket buffers, no slow start after idle, TCP fast open, swappiness 1 |
| `hyperstream_host` | EXPERIMENTAL, only with `hyperstream_enabled`: `vm.nr_hugepages` (2 MB pages) and `/dev/hugepages`; `vfio` and `vfio-pci` at boot with `enable_unsafe_noiommu_mode=1` (Nitro exposes no guest IOMMU); a systemd-networkd drop-in that leaves the hyperstream ENI (by MAC, from the inventory) unmanaged, so the kernel never gives it an address or a route; `hyperstream-nic-bind.service`, enabled only with `hyperstream_dpdk`, finds the ENI at device index 1 through the metadata, records its PCI address, MAC, address, mask and gateway in `/etc/hyperstream/nic.env` and binds it to `vfio-pci` before docker starts |

The play ends by printing the addresses on the interface: the primary
private address plus one `/32` per extra elastic IP.

### CrowdSec

CrowdSec reads sshd's journal, matches the `sshd` scenarios (bursts of
failed logins, user enumeration, slow brute force) and the bouncer drops the
source address for four hours by default, longer on repeat. The community
blocklist is applied as well. A successful key login is not an event; several
failed logins within a minute from one address are.

```bash
sudo cscli decisions list                       # banned addresses, reason, expiry
sudo cscli decisions delete --ip 203.0.113.7    # unban
sudo cscli alerts list                          # what fired
sudo cscli metrics                              # lines read, scenarios hit, bouncer pulls
sudo nft list table ip crowdsec                 # the live drop set
```

A ban applies to the one address that failed, never to the key or the
account: log in from any other address (a whitelisted one from
`crowdsec_whitelist_cidrs`, or any address that has not been banned) and
lift it with `cscli decisions delete`. The AWS serial console is not a way
in: every account is key-only, and the console prompt needs a password. Packages come from CrowdSec's repository at the
`bookworm` suite (`crowdsec_repo_suite`); there is no `trixie` suite yet and
the binaries run on trixie. `crowdsec_enroll_key` enrolls the host in the
CrowdSec console; optional.

### 4. Hand-over to trading-bots

The play generated a GitHub deploy key for the `trading-bot` account and
printed its public half in the summary (`just deploy-key` prints it again).
Add it to the `trading-bots` repository as a read-only deploy key
(Settings, Deploy keys), then, as `trading-bot` on the host (`just ssh-bot`):

```bash
git clone git@github.com:lauris101/trading-bots.git && cd trading-bots
infra/scripts/bootstrap.sh prod            # writes .env; then fill in:
#   DATABASE_URL / CLICKHOUSE_URL           via the db host's tunnel hostnames (../cloudflare)
#   BOT_CPUSET=2-7                          the isolated cores plus two shared cores
#   BOT_HOUSEKEEPING_CPUS=2-3               the bot's non-hot threads
#   BOT_PARSE_CPUS=4 BOT_STRATEGY_CPUS=5,6 BOT_SEND_CPUS=7   one spinner per isolated core
#   DATA_BASE_DIR= LOGS_BASE_DIR=           empty, as data_base_dir/logs_base_dir
#   CLOUDFLARE_TUNNEL_TOKEN                 `just app-token` in ../cloudflare
#   HL_PRIVATE_KEY                          the venue signing key (hex)
infra/scripts/deploy.sh prod vX.Y.Z        # builds on the host with target-cpu=native
```

The bot's status page lists the three addresses under `network` (provider
`aws`, each `configured: true`).

## Costs (Tokyo, on-demand, approximate)

| item | per month |
|---|---|
| c7g.2xlarge | USD 265 (a 1-year compute savings plan reduces this by about a third) |
| 3 public IPv4 addresses | USD 11 (charged attached or not) |
| 80 GB gp3 | USD 8 |
| egress | first 100 GB free, then about USD 0.11/GB |

## Day 2

- **Narrow SSH to fixed addresses, or change the key:** edit
  `terraform.tfvars`, `just apply`; edit `vars.yml`,
  `just tags trading_bot_user,sshd`.
- **Add an elastic IP:** raise `elastic_ip_count`, `just apply`. The timer
  on the host picks the new private address up within a minute; the bot
  uses it from its next start.
- **Rebuild on a new Debian image or in another zone:** `just rebuild`,
  then `just provision`. The elastic IPs stay.
- **Lost state:** restore from the bucket or a `just state-backup` copy
  (repository README); with neither, `terraform import` each resource by
  id; the tag `project=trading-bots` finds them in the console.

## Park (stop paying for the instance, keep the addresses)

```bash
# on the host first, so the bot sweeps its orders and the stack stops cleanly:
#   cd trading-bots && just down
scp trading-host:trading-bots/.env ~/trading-host.env    # the disk goes with the instance
just park          # destroys aws_instance.host (and its EIP associations); the 3 EIPs stay
```

What survives: the three elastic IPs (allocated, unassociated: about
0.005 USD per hour each), the security group, the subnet, the Cloudflare
tunnel and Access configuration, the Terraform state. What is gone: the root
disk, so everything on the host: the trading-bots checkout and its `.env`,
the docker images, the GitHub deploy key.

```bash
just unpark        # a new instance on the same EIPs
ssh-keygen -R <ip> # the new host key, per address you connect to
just provision     # the OS again; the summary prints a NEW github deploy key
```

Then the hand-over again: clone (after adding the new deploy key on GitHub),
put `.env` back, `infra/scripts/deploy.sh prod <tag>`. `bypass_cidrs` and the
tunnel token are unchanged.

## Rebuilding on a new image

The instance carries `ignore_changes = [ami]`, so a newer image never
replaces a running trading host by surprise. Changing image is therefore
deliberate: park, apply, unpark.

```bash
# on the host: keep what the disk is about to lose
cd trading-bots && just down
scp trading-host:trading-bots/.env ~/trading-host.env
scp trading-host:.config/hl/key ~/hl-key            # the signing key
just park                    # instance gone, the 3 elastic IPs stay
just apply                   # picks up the new AMI in the data source
just unpark                  # a new instance on the same addresses
ssh-keygen -R <ip>           # per address you connect to
just provision               # prints a NEW github deploy key
```

Then the hand-over again: add the deploy key on GitHub, clone, restore
`.env` and the signing key, `docker load` or rebuild the Seastar toolchain
image (`just hyperstream-toolchain-on-host`, 20-40 minutes -- the long pole
in the whole rebuild), `just hyperstream-image`, and
`infra/scripts/deploy.sh prod <tag>`. `bypass_cidrs`, the tunnel token and
the Cloudflare configuration are untouched throughout.

This host runs **Ubuntu 24.04 (noble) arm64**. It was Debian 13 until
2026-09-18; see the AMI data source for why it is not any more.

## Tear down

`just destroy` first applies `termination_protection=false` to the
instance, then destroys everything; terraform asks for confirmation at each
step. The destroy plan lists about 20 resources.

| resource | on destroy | cost after |
|---|---|---|
| instance | terminated | none |
| root volume | deleted with it | none |
| elastic IPs | released | none |
| ENI, security group, subnet, route table, internet gateway, VPC, key pair | deleted | none |

Nothing else is created (no snapshots, no NAT gateway, no load balancer, no
paid monitoring). The IAM user and the local state file remain.

A stopped (not destroyed) instance keeps the volume and the three IPv4
addresses: about USD 19 a month.

Elastic IPs are released on destroy; a later apply gets new ones, and
allow-lists that name them (Cloudflare Access `bypass_cidrs`) must be
updated. To keep them across a destroy: `terraform state rm 'aws_eip.host'`
before destroying, import them again later; idle EIPs cost USD 11 a month.

## Hyperstream (experimental)

The hyperstream producer (trading-bots branch `hyperstream`) races several
Binance connections on its own two cores and hands the first arrival of
every update to the bot through shared memory; with DPDK it drives its own
network interface with no kernel on the path. The host side, in order:

1. `terraform.tfvars`: `hyperstream_eni = true`; `just apply`. A second ENI
   is attached to the running instance as device 1 (no replacement) and the
   LAST elastic IP is moved onto it. That is always a SECONDARY private
   address: the ENI's primary carries the host's default route, so the
   ordering behind these associations puts it first and it is never the one
   taken. `just ips` shows the mapping and the `hyperstream_eni` output
   names the private address that EIP used to map to: it has no public
   mapping now and this subnet has no NAT, so anything bound to it reaches
   nothing. Put it in the bot's `network.exclude_ips`.

   Enabling this on a host whose associations predate the ordering change
   re-associates all of the elastic IPs, a few seconds each, so do it in
   the same window as the rest.
2. `vars.yml`: `hotpath_isolated_cpus: "2-7"`, `hotpath_housekeeping_cpus:
   "0-1"`, `hyperstream_enabled: true`, `hyperstream_cpus: "2-3"`,
   `hyperstream_dpdk: false`; `just provision`. The kernel command line
   changes, so the box reboots once. Hugepages and vfio are in place; the
   ENI is idle.
3. trading-bots `.env`: `HYPERSTREAM_CPUSET=2-3`, `BOT_CPUSET=0-1,4-7`; the
   bot's `hot_path.*_cpus` stay on 4-7. In the bot's stored config, list the
   hyperstream elastic IP (the `hyperstream_eni` output) under
   `network.exclude_ips`; `network.aws_primary_eni_only` (default on) keeps
   the bot's discovery to the primary ENI regardless. Run the producer on
   the kernel stack (compose profile `hyperstream`) and measure the race.
   In this phase the producer leaves from the host's default route (the
   primary address), not from its own EIP.
4. For the DPDK run: `hyperstream_dpdk: true`; `just tags hyperstream`.
   **This does not work on a Debian kernel** -- see the note on
   `hyperstream_dpdk` in `vars.yml.example`: no-IOMMU vfio is compiled out
   of every Debian flavour, and Nitro has no guest IOMMU, so the bind fails
   with `probe with driver vfio-pci failed with error -22`. The rest of
   this step is what to do once that is solved. The
   bind unit hands the ENI to `vfio-pci` now and on every boot, and writes
   `/etc/hyperstream/nic.env`: the PCI address, MAC, IPv4, netmask and
   gateway, plus two things the producer cannot work out once the kernel is
   off its path -- the PRIMARY ENI's address to reach control on, and venue
   addresses resolved while DNS still worked, to seed the peer pool. The
   interface disappears from `ip link`; the primary ENI is untouched.

   Two more things must be true, or the producer starts and then cannot
   reach control. Seastar's native stack has no loopback, so control has to
   be listening on the host's primary private address: set `API_BIND` to it
   in the trading-bots `.env` (never `0.0.0.0` -- the API has no auth of its
   own and this host has public addresses). And `just apply` must have run
   with `hyperstream_eni = true` since this change, which is what adds the
   security-group rule admitting that one source address on `control_port`.

   Then run the producer under the trading-bots compose profile
   `hyperstream-dpdk` INSTEAD of `hyperstream`: it is the same image with
   the privileges, hugepages, `/dev/vfio` and the PCI tree, and it reads
   `nic.env` for all of the above. The kernel-stack profile would have no
   interface left to use.

Undo: `hyperstream_dpdk: false` and `just tags hyperstream` disables the
unit (a reboot returns the ENI to the kernel); `hyperstream_eni = false`
and `just apply` detaches the ENI and moves the EIP back to the primary
ENI's private address.

### The producer image

The host compiles no Seastar. trading-bots keeps two images: the toolchain
(`hyperstream/Dockerfile.seastar`, Seastar with DPDK, 20-40 minutes and
several GB) is built once on the dev box or in CI (`just
hyperstream-toolchain`, `just hyperstream-toolchain-save`) and loaded on the
host with `docker load`; the producer (`hyperstream/Dockerfile`) starts
from it and compiles in about a minute, which is all a deploy rebuilds. No
Seastar toolchain is installed on the host by this playbook.

## Settings summary

- Port 22 open to the internet (`ssh_allowed_cidrs` default), keys only,
  CrowdSec with the nftables bouncer; the dev box's addresses whitelisted.
  Everything else is reached through the Cloudflare tunnel (`../cloudflare`).
- One SSH key for `admin` and `trading-bot`; `trading-bot` has passwordless
  sudo and is in the docker group; `admin` and `trading-bot` are the only
  SSH users.
- Cores `4-7` isolated (`isolcpus=domain,managed_irq`): the kernel and every
  unpinned task stay off them, the scheduler does not balance between them,
  and device interrupts avoid them, so the bot pins one spinner per isolated
  core (`hot_path.*_cpus`). Cores `0-3` are shared by everything else
  (`hotpath_housekeeping_cpus`); the bot's non-hot threads use `2-3`
  (`BOT_CPUSET=2-7`) and the network queue interrupts are pinned to `0-3` by
  `bot-irq-affinity.service` (`irqaffinity=0-3` for the rest). c7g has no
  SMT. With hyperstream the isolated set is `2-7`, the producer takes `2-3`
  (`HYPERSTREAM_CPUSET`), the bot's non-hot threads move to `0-1`
  (`BOT_CPUSET=0-1,4-7`) and interrupts to `0-1`.
- No root volume snapshots; a rebuild is apply, provision, deploy.
- Terraform state in R2; termination protection on.
- The ENI's secondary private addresses are chosen by AWS from the subnet.
  Allow-lists use the elastic IPs, which are stable.
