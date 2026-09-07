# trading-bots-aws-setup

The AWS trading host, as code. Two layers, two tools, run from your laptop:

| layer | tool | what it makes |
|---|---|---|
| AWS resources | **terraform** (`terraform/`) | a VPC and public subnet in Tokyo, a `c7g.2xlarge` Graviton instance on Debian 13 arm64, an 80 GB encrypted gp3 root volume, one network interface carrying 3 private addresses, 3 elastic IPs bound to them, a security group that admits SSH from your addresses and nothing else |
| the OS | **ansible** (`ansible/`) | packages, UTC + Amazon time sync, sshd hardening, the `trading-bot` account with the SSH key you choose (sudo, docker group), Docker Engine + compose, a unit that puts the secondary IPs on the interface, kernel core isolation and network sysctls, `/data` and `/logs` roots |

Nothing here knows about the trading key, the database, or Cloudflare.
Those come afterwards, from the `trading-bots` repository, as the
`trading-bot` user (see "Hand-over" below).

## The process

```
laptop                                     AWS (ap-northeast-1)
------                                     --------------------
1. just init / plan / apply  --terraform-->  VPC, subnet, IGW, SG(22 only), ENI(3 IPs),
                                             c7g.2xlarge Debian 13, 80 GB root, 3 EIPs
2. just inventory            <-- outputs --  first EIP + instance id -> ansible/inventory/hosts.yml
3. just provision            --ansible---->  ssh admin@EIP: base, sshd, trading-bot user,
   (reboots once, for isolcpus)              docker, secondary IPs, hotpath
4. ssh trading-bot@EIP                       clone trading-bots, bootstrap.sh, deploy.sh prod vX.Y.Z
```

### 0. Tools and credentials

- `terraform` >= 1.6 (or OpenTofu: set `tf := "tofu -chdir=terraform"` in
  the justfile), `ansible-core` >= 2.15 with the `ansible.posix` and
  `community.general` collections, `just`, and the `aws` CLI for the odd
  check. `just tools` installs them (Homebrew on a Mac, apt and pipx on
  Debian) and pulls the collections.

#### On a Mac

```bash
# Homebrew, if not there yet: https://brew.sh
brew install just git
git clone git@github.com:lauris101/trading-bots-aws-setup.git && cd trading-bots-aws-setup
just tools                     # terraform (HashiCorp tap), ansible, awscli, the collections

# one SSH key for the box (skip if you already have one you want to use)
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_trading -C "trading-host"
cat ~/.ssh/id_ed25519_trading.pub      # -> ssh_public_key in terraform.tfvars

# tell ssh to use it for the host (works for `just ssh`, `just ssh-bot`, ansible)
cat >> ~/.ssh/config <<'EOF'
Host trading-host *.compute.amazonaws.com
  IdentityFile ~/.ssh/id_ed25519_trading
  IdentitiesOnly yes
  ServerAliveInterval 30
EOF
```

Notes for macOS: Terraform comes from the `hashicorp/tap` because the
core Homebrew formula stopped at the last MPL release. `brew install
ansible` gives the full community package (Python included), so no pipx.
If `ansible-playbook` ever dies with an `objc ... fork()` crash, put
`export OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES` in your shell profile;
it is a macOS Python quirk, not an Ansible bug. The AWS credentials file is
`~/.aws/credentials` on a Mac too, and `aws configure --profile trading`
writes it for you. Apple silicon or Intel both work: nothing here runs
locally except the two tools.

If `just ssh`'s inventory host is the bare IP rather than a name, add that
IP to the `Host` line above or pass `-i ~/.ssh/id_ed25519_trading`; the
inventory sets `ansible_user`, and Ansible reads `~/.ssh/config` like ssh
does.
- AWS credentials: see "Credentials" just below. Nothing is stored in this
  repository.
- One SSH public key. Terraform gives it to the AMI's `admin` user at
  launch (Ansible logs in with it) and carries it into the inventory;
  Ansible gives the same key to `trading-bot`. A different key for
  `trading-bot` is one line in `vars.yml` if you ever want it.

#### Credentials

The simplest arrangement that is still narrow: a dedicated IAM user for
this repository, with an access key in a named profile, and a policy that
allows EC2 and VPC only in Tokyo.

1. IAM console, Users, Create user `terraform-trading`. No console access.
2. Permissions: Create inline policy, JSON tab, paste
   `iam/terraform-policy.json`. It allows every `ec2:` action in
   `ap-northeast-1` only, read-only describes elsewhere (for plans), and
   denies `TerminateInstances` on terraform-managed resources unless the
   session has MFA. Terraform therefore cannot destroy the host by
   accident; a deliberate destroy is done from a console session with MFA
   or by removing that statement.
3. Security credentials, Create access key, "Application running outside
   AWS". Put it in `~/.aws/credentials`:

   ```ini
   [trading]
   aws_access_key_id     = AKIA...
   aws_secret_access_key = ...
   region                = ap-northeast-1
   ```

4. `aws_profile = "trading"` in `terraform.tfvars` (the example has it).

Rotate the key from the same page when needed; nothing else changes. Not
chosen: IAM Identity Center (SSO) and `aws-vault`, correct for a team,
more moving parts than one operator needs; the root account, never.

### 1. AWS resources

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # fill in
just init
just plan        # fmt, validate, and the plan: ~20 resources
just apply       # creates them (a few minutes), then writes the inventory
just ips         # elastic IP -> private address
```

`terraform.tfvars` holds the two things that are yours: the SSH allow-list
(`ssh_allowed_cidrs`, one /32 per address you operate from; `0.0.0.0/0` is
refused) and the admin public key. Everything else has a default in
`variables.tf`. State is local (`terraform/*.tfstate`, gitignored): back it
up with your secrets.

What the plan contains and why:

- **Own VPC** (`10.20.0.0/16`, one public subnet in `ap-northeast-1a`)
  rather than the default VPC: nothing else shares the address space or the
  route table, and the box's network is fully described here.
- **Availability zone.** Hyperliquid's validators run in AWS Tokyo across
  several availability zones, and its API is fronted by CloudFront, so
  there is no single "Hyperliquid AZ" to sit next to; the region is what
  matters (Tokyo to the validators is 2-3 ms, Europe 200+ ms), and the
  order round trip is dominated by the venue's own processing (about 0.9 s
  median measured from AWS Tokyo, of which about 5 ms is network). AZ
  names are also shuffled per account, so a name someone else reports
  means nothing here. The way to choose is to measure: `just latency`
  runs TCP connects from the host to every API address. To try another
  AZ, change `availability_zone` and `just apply` + `just provision`: the
  subnet, ENI and instance are replaced, the **elastic IPs are kept**
  (they are region resources), so nothing outside changes.
- **Security group = the firewall.** Inbound: TCP 22 from the allow-list.
  Outbound: everything (venue websockets, the Cloudflare tunnel, the
  database over the tunnel, apt). It is enforced at the interface, so
  nothing on the host can open a port to the internet by mistake. No host
  firewall is layered on top: docker rewrites iptables at every start, and a
  second layer that fights it is a source of outages, not safety.
- **One ENI, N private addresses, N elastic IPs.** The instance type allows
  15 addresses per interface; `elastic_ip_count` (default 3) creates that
  many private addresses and elastic IPs and binds them one-to-one. The bot
  discovers them through the instance metadata (`network.ip_provider:
  auto`) and gives each socket its own source address, so each elastic IP
  is a separate venue rate-limit budget.

  This is NAT, and it is the only way a VPC does public IPv4: the
  interface never carries a public address (unlike Hetzner, where the
  additional IP sits directly on `eth0`); the internet gateway rewrites
  each private address to its elastic IP, one-to-one and stateless, so
  there is no shared NAT gateway, no port pool to exhaust and no
  connection table to fill. Every EC2 instance with a public address works
  this way, so the cost is already in every latency number ever measured
  from AWS. For the bot it is the same "discover a pool, bind each socket
  to one address" as on Hetzner, done by the `aws` provider: it reads the
  private-to-public mapping from the metadata (`ipv4-associations`), binds
  the private address, and reports both, so `/status.network` shows the
  elastic IP the venue sees next to the address the socket bound. The
  `secondary_ips` role is the one thing the host must do for this: put the
  extra private addresses on the interface, or the kernel refuses to send
  from them.
- **IMDSv2 only**, hop limit 2, so a process in a docker bridge network
  can still read the metadata.
- **Root volume** 80 GB gp3, encrypted, deleted with the instance. Debian's
  cloud image grows its filesystem into the volume at first boot.
- **AMI pinned after launch** (`lifecycle.ignore_changes = [ami]`): a newer
  Debian image never replaces the running host on a routine apply.
- **Termination protection on** (`termination_protection = true`). To
  destroy, set it to `false`, apply, then `just destroy`.

### 2. Inventory

`just apply` already ran it; `just inventory` regenerates
`ansible/inventory/hosts.yml` from the terraform outputs (first elastic IP,
`admin` user, instance id, the list of elastic IPs). `just ping` proves
Ansible can log in.

### 3. The OS

```bash
cp ansible/vars.yml.example ansible/vars.yml     # the trading-bot key, cores, dirs
just check       # dry run with diffs
just provision   # the real thing; reboots once on a fresh host
```

`vars.yml` is where the **SSH key for `trading-bot`** is set
(`trading_bot_public_key`: by default the key from `terraform.tfvars`,
otherwise a key line or a path to a `.pub` file), whether it
gets passwordless sudo (`trading_bot_sudo`, default true: one operator, one
box, and `deploy.sh` needs apt), and which cores the kernel keeps off
(`hotpath_isolated_cpus`, default `2-5`; it must equal `BOT_CPUSET` in the
trading-bots `.env`).

Roles, in order:

| role | does |
|---|---|
| `base` | hostname, UTC, packages (`git just jq curl zstd chrony unattended-upgrades ...`), chrony on the Amazon Time Sync Service (`169.254.169.123`), security updates without automatic reboots, bounded journald |
| `sshd` | keys only, no root, `AllowUsers admin trading-bot`, short grace time; disables any image drop-in that still allows passwords |
| `trading_bot_user` | the account, its one authorized key (exclusive), sudoers entry, `/data/data/trading-bots` and `/logs/logs/trading-bots` owned by it, an owner-only `~/.config/hl` for the venue key you place by hand |
| `docker` | Docker Engine + buildx + compose plugin from download.docker.com (arm64), `live-restore`, `trading-bot` in the docker group |
| `secondary_ips` | `aws-secondary-ips` script + systemd service and 1-minute timer: reads the ENI's addresses from the metadata and adds the missing ones as `/32`s. Without this the kernel cannot send from the second and third elastic IP |
| `hotpath` | `isolcpus nohz_full rcu_nocbs` for the bot's cores via a grub drop-in (reboot only when the line changed), and sysctls: 16 MB socket buffers, no slow-start after idle, TCP fast open, swappiness 1 |

The play ends by printing the addresses the interface carries: the primary
private address plus one `/32` per extra elastic IP.

### 4. Hand-over to trading-bots

As `trading-bot` on the box (`just ssh-bot`):

```bash
git clone git@github.com:lauris101/trading-bots.git && cd trading-bots
infra/scripts/bootstrap.sh prod            # .env, then fill it in:
#   DATABASE_URL / CLICKHOUSE_URL through the db host's tunnel hostnames
#   BOT_CPUSET=2-5                          (equals hotpath_isolated_cpus)
#   DATA_BASE_DIR=/data  LOGS_BASE_DIR=/logs
#   CLOUDFLARE_TUNNEL_TOKEN for ui./api./metrics.<domain>
# place the venue key at ~/.config/hl/key (mode 0600), never in git
infra/scripts/deploy.sh prod vX.Y.Z        # builds natively on Graviton (target-cpu=native)
```

The bot's status page then shows all three addresses under `network`
(provider `aws`, each `configured: true`) and the send workers and market
data sockets spread across them.

## Costs (Tokyo, on-demand, rough)

| item | per month |
|---|---|
| c7g.2xlarge | about USD 265 (a 1-year compute savings plan takes roughly a third off) |
| 3 public IPv4 addresses | about USD 11 (AWS charges every public IPv4, attached or not) |
| 80 GB gp3 | about USD 8 |
| egress | first 100 GB free, then about USD 0.11/GB; the scraper runs on the database host, so the trading host sends little |

## Day 2

- **Change the allow-list or the key:** edit `terraform.tfvars`, `just apply`
  (the security group updates in place); edit `vars.yml`, `just tags
  trading_bot_user,sshd`.
- **Add an elastic IP:** raise `elastic_ip_count`, `just apply`; the timer
  on the host picks the new private address up within a minute, and the
  bot sees it at its next start.
- **Rebuild on a new Debian image:** `terraform taint aws_instance.host`
  (or `-replace`), apply, provision. The elastic IPs survive (they belong
  to the ENI, which is not replaced), so DNS and allow-lists elsewhere do
  not change.
- **Lose the state file:** `terraform import` each resource by id (the
  instance, ENI, EIPs, SG, VPC pieces); tags `project=trading-bots` find
  them in the console.

## Decisions taken here, and open questions

Taken, easy to change:

- SSH allow-list example is the dev box's two addresses; nothing else is
  reachable from the internet. The Cloudflare tunnel (outbound) is how the
  UI and API are reached; that is configured in trading-bots, not here.
- One SSH key for `admin` and `trading-bot`.
- `trading-bot` has passwordless sudo and is in the docker group. The AMI's
  `admin` user is kept for Ansible; both are the only SSH users.
- No host firewall on top of the security group (see above).
- Cores `2-5` isolated for the bot; `0-1` for the OS, control, cloudflared,
  fluentd; `6-7` spare. c7g has no SMT, so no sibling to worry about.
- Local terraform state; termination protection on.

- No root volume snapshots: the stack's state is in the database host and
  in git, so a rebuild is `apply + provision + deploy`.
- Availability zone `ap-northeast-1a` to start; measure with `just latency`
  and move if another AZ is clearly better (the elastic IPs stay).
- Credentials: a dedicated IAM user with the Tokyo-only policy in `iam/`.

Open, for you to decide:

1. **Static private addresses.** The ENI's secondary addresses are picked by
   AWS from the subnet. If you want them fixed (for allow-lists on the
   database side, use the elastic IPs, which are stable regardless), they
   can be listed explicitly.
2. **Reserved capacity / savings plan** once the box has run for a few
   weeks on demand.
