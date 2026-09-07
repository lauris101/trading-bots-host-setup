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

# The security group IS the firewall: stateful, enforced at the ENI, not
# bypassable from inside the OS. Inbound is SSH from the allow-list only.
# Everything the host runs (Cloudflare tunnel, venue websockets, the
# database over the tunnel) is outbound.
resource "aws_security_group" "host" {
  name        = "${var.name}-host"
  description = "SSH from the allow-list; all outbound"
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

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.host.id
  description       = "all outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# --- the instance ------------------------------------------------------------

resource "aws_key_pair" "admin" {
  key_name   = "${var.name}-admin"
  public_key = var.admin_public_key
}

# Latest official Debian 13 (trixie) arm64 image. Debian's cloud team
# publishes under this account id in every region.
data "aws_ami" "debian13_arm64" {
  most_recent = true
  owners      = ["136693071363"]

  filter {
    name   = "name"
    values = ["debian-13-arm64-*"]
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
  ami           = data.aws_ami.debian13_arm64.id
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

# private_ips is a set; sorting it gives a stable index -> address mapping,
# so the same EIP stays on the same private address across applies.
locals {
  private_ips = sort(tolist(aws_network_interface.primary.private_ips))
}

resource "aws_eip_association" "host" {
  count = var.elastic_ip_count

  allocation_id        = aws_eip.host[count.index].id
  network_interface_id = aws_network_interface.primary.id
  private_ip_address   = local.private_ips[count.index]

  depends_on = [aws_instance.host]
}
