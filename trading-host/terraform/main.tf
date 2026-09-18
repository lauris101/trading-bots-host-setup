# The trading host: one Graviton instance in its own small VPC, several
# elastic IPs on one network interface, a security group that admits SSH
# and nothing else. Everything inside the OS is Ansible's job (../ansible).

# --- network -----------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = var.name }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = var.name }
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.subnet_cidr
  availability_zone = var.availability_zone

  # No auto-assigned public IP: the elastic IPs below are the public side.
  map_public_ip_on_launch = false

  tags = { Name = "${var.name}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.name}-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# --- firewall ----------------------------------------------------------------

# The security group is the outer firewall: stateful, enforced at the ENI,
# not bypassable from inside the OS. Inbound is SSH only, from
# ssh_allowed_cidrs (the internet by default: no fixed address to allow;
# CrowdSec on the host bans brute-forcers). Everything the host runs
# (Cloudflare tunnel, venue websockets, the database over the tunnel) is
# outbound.
resource "aws_security_group" "host" {
  name        = "${var.name}-host"
  description = "SSH in (ssh_allowed_cidrs, the internet by default); all outbound"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.name}-host" }
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each = toset(var.ssh_allowed_cidrs)

  security_group_id = aws_security_group.host.id
  description       = "ssh"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

# The hyperstream producer on Seastar's native stack has no loopback: it
# cannot reach control at 127.0.0.1, so it goes across the VPC from the
# hyperstream ENI's address to the primary ENI's. One source address, one
# port, and only while that ENI exists. Control must also listen on more
# than loopback for this to land (API_BIND in the trading-bots .env).
resource "aws_vpc_security_group_ingress_rule" "hyperstream_to_control" {
  count = var.hyperstream_eni ? 1 : 0

  security_group_id = aws_security_group.host.id
  # AWS accepts only a-zA-Z0-9. _-:/()#,@[]+=& and a few more here: no
  # arrows, and a rejected description fails the whole apply.
  description = "hyperstream producer (native stack) to control"
  cidr_ipv4   = "${aws_network_interface.hyperstream[0].private_ip}/32"
  ip_protocol = "tcp"
  from_port   = var.control_port
  to_port     = var.control_port
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.host.id
  description       = "all outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# --- the instance ------------------------------------------------------------

resource "aws_key_pair" "admin" {
  key_name   = "${var.name}-admin"
  public_key = var.ssh_public_key
}

# Latest official Ubuntu 24.04 (noble) arm64 image, published by Canonical
# under this account id in every region.
#
# Ubuntu rather than Debian for one reason: CONFIG_VFIO_NOIOMMU. Nitro
# exposes no IOMMU to the guest, so binding a NIC to vfio-pci for DPDK
# needs VFIO's no-IOMMU mode, and Debian sets it off in the config
# fragment every flavour inherits -- the bind fails with
#   vfio-pci ...: probe with driver vfio-pci failed with error -22
# Ubuntu ships CONFIG_VFIO_NOIOMMU=y in both the GA and HWE arm64 kernels
# (verified 2026-09-18 against the shipped configs).
#
# The playbook targets Ubuntu, not "a Debian-family box": the apt repo
# URLs name it. Changing distribution again means editing those too.
data "aws_ami" "ubuntu_arm64" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"]
  }
  filter {
    name   = "architecture"
    values = ["arm64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# One ENI, created on its own so it can carry N private addresses; each
# elastic IP maps to one of them. The OS must also configure the secondary
# addresses on the interface (Ansible role `secondary_ips` does, from the
# instance metadata), or the kernel cannot use them as source addresses.
resource "aws_network_interface" "primary" {
  subnet_id         = aws_subnet.public.id
  security_groups   = [aws_security_group.host.id]
  private_ips_count = var.elastic_ip_count - 1
  description       = "${var.name} primary ENI (${var.elastic_ip_count} addresses)"

  tags = { Name = "${var.name}-eni0" }
}

resource "aws_instance" "host" {
  ami           = data.aws_ami.ubuntu_arm64.id
  instance_type = var.instance_type
  key_name      = aws_key_pair.admin.key_name
  ebs_optimized = true

  network_interface {
    network_interface_id = aws_network_interface.primary.id
    device_index         = 0
  }

  root_block_device {
    volume_size           = var.root_volume_gb
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true

    tags = { Name = "${var.name}-root" }
  }

  # IMDSv2 only. The hop limit of 2 lets a process inside a docker bridge
  # network reach the metadata service too (the bot itself runs with
  # network_mode: host, control does not).
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "enabled"
  }

  disable_api_termination = var.termination_protection
  monitoring              = false

  tags = { Name = var.name }

  lifecycle {
    # A newer Debian AMI must never replace the running host on a routine
    # apply. Upgrading the image is a deliberate rebuild.
    ignore_changes = [ami]
  }
}

# --- elastic IPs -------------------------------------------------------------

resource "aws_eip" "host" {
  count  = var.elastic_ip_count
  domain = "vpc"

  tags = { Name = "${var.name}-${count.index}" }
}

# private_ips is a set, so it needs an order to give a stable index ->
# address mapping and keep the same EIP on the same private address across
# applies. The ENI's PRIMARY address goes first and the secondaries follow,
# sorted.
#
# Not a plain sort of all of them. The primary address carries the host's
# default route: everything that does not bind a source address leaves from
# it -- the cloudflared tunnel, the database tunnel, apt, docker. The
# hyperstream ENI takes the LAST elastic IP, so a plain sort can put the
# primary last and strand the whole box's outbound traffic (on this host
# 10.20.1.50 sorts after .249 and .28, and is the primary). First means it
# is never the one taken.
locals {
  private_ips = concat(
    [aws_network_interface.primary.private_ip],
    sort(tolist(setsubtract(
      aws_network_interface.primary.private_ips,
      [aws_network_interface.primary.private_ip],
    ))),
  )
}

# --- the hyperstream ENI (experimental) ----------------------------------------

# A second interface for the hyperstream producer (trading-bots branch
# hyperstream): DPDK takes a whole NIC, so this one is bound to vfio-pci by
# the OS (ansible role hyperstream_host) and the kernel never sees it, while
# the primary ENI keeps SSH, control and the Hyperliquid side. Attached to
# the running instance as device 1, never through the instance's own
# network_interface block, which would replace the instance.
resource "aws_network_interface" "hyperstream" {
  count = var.hyperstream_eni ? 1 : 0

  subnet_id       = aws_subnet.public.id
  security_groups = [aws_security_group.host.id]
  description     = "${var.name} hyperstream ENI (DPDK)"

  tags = { Name = "${var.name}-eni1-hyperstream" }
}

resource "aws_network_interface_attachment" "hyperstream" {
  count = var.hyperstream_eni ? 1 : 0

  instance_id          = aws_instance.host.id
  network_interface_id = aws_network_interface.hyperstream[0].id
  device_index         = 1
}

locals {
  # The last elastic IP moves to the hyperstream ENI when it exists.
  hyperstream_eip_index = var.hyperstream_eni ? var.elastic_ip_count - 1 : -1
}

resource "aws_eip_association" "host" {
  count = var.elastic_ip_count

  allocation_id = aws_eip.host[count.index].id
  network_interface_id = (
    count.index == local.hyperstream_eip_index
    ? aws_network_interface.hyperstream[0].id
    : aws_network_interface.primary.id
  )
  private_ip_address = (
    count.index == local.hyperstream_eip_index
    ? aws_network_interface.hyperstream[0].private_ip
    : local.private_ips[count.index]
  )

  depends_on = [aws_instance.host, aws_network_interface_attachment.hyperstream]
}
