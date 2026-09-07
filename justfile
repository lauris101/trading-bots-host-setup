# trading-bots-aws-setup task runner. `just --list` for an overview.
# Two layers: terraform makes the AWS resources, ansible makes the OS.

tf := "terraform -chdir=terraform"
ansible := "ansible-playbook -i ansible/inventory/hosts.yml"

# Install the tools: Homebrew on a Mac, apt + pipx on Debian/Ubuntu (README "Tools")
tools:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "$(uname)" = Darwin ]; then
        command -v brew >/dev/null || { echo "install Homebrew first: https://brew.sh"; exit 1; }
        brew list hashicorp/tap/terraform >/dev/null 2>&1 || brew install hashicorp/tap/terraform
        brew list ansible >/dev/null 2>&1 || brew install ansible
        brew list awscli >/dev/null 2>&1 || brew install awscli
    else
        command -v terraform >/dev/null || echo "terraform: https://developer.hashicorp.com/terraform/install (or apt install opentofu and set tf := \"tofu -chdir=terraform\" here)"
        command -v ansible-playbook >/dev/null || { command -v pipx >/dev/null || sudo apt-get install -y pipx; pipx install --include-deps ansible-core; }
    fi
    ansible-galaxy collection install -r ansible/requirements.yml
    terraform version | head -1; ansible --version | head -1

# --- AWS resources (terraform) ------------------------------------------------

# Download the provider, once
init:
    {{tf}} init

# Show what would change
plan:
    {{tf}} fmt -check -recursive
    {{tf}} validate
    {{tf}} plan

# Create or update the AWS resources, then refresh the ansible inventory
apply:
    {{tf}} apply
    just inventory

# Write ansible/inventory/hosts.yml from the terraform outputs
inventory:
    mkdir -p ansible/inventory
    {{tf}} output -raw ansible_inventory > ansible/inventory/hosts.yml
    @echo "wrote ansible/inventory/hosts.yml:"; cat ansible/inventory/hosts.yml

# The elastic IPs and what each is bound to
ips:
    {{tf}} output addresses

# --- the OS (ansible) ---------------------------------------------------------

# Check ansible can reach the host as admin
ping:
    ansible -i ansible/inventory/hosts.yml all -m ping

# Dry run of the playbook: what would change on the host
check:
    {{ansible}} ansible/site.yml --check --diff

# Configure the host (idempotent; reboots only if the kernel command line changed)
provision:
    {{ansible}} ansible/site.yml --diff

# Run a subset, e.g. `just tags trading_bot_user,sshd`
tags tags:
    {{ansible}} ansible/site.yml --diff --tags {{tags}}

# SSH in as admin (ansible's user)
ssh:
    ssh admin@$({{tf}} output -raw ssh | sed 's/^ssh admin@//')

# SSH in as the trading-bot account
ssh-bot:
    ssh trading-bot@$({{tf}} output -raw ssh | sed 's/^ssh admin@//')

# TCP connect latency from the host to every Hyperliquid API address (compare AZs with this)
latency samples="20":
    ssh admin@$({{tf}} output -raw ssh | sed 's/^ssh admin@//') 'bash -s' -- {{samples}} < scripts/hl-latency.sh

# --- teardown -----------------------------------------------------------------

# Destroy everything (refused while termination_protection = true; flip it in terraform.tfvars and apply first)
destroy:
    {{tf}} destroy
