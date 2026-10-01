# Throwaway infrastructure for one measurement: an identical instance in each
# availability zone, so the venue legs can be timed from all of them at once.
#
# It is deliberately SEPARATE from ../terraform: its own VPC, its own local
# state file, nothing shared and nothing imported. A `terraform destroy` here
# cannot reach the trading host, which is the point -- this stack is built to
# be thrown away in a hurry.
#
# Zone IDs are the real identifier; the per-account names are aliases. This
# account (2026-10-01):
#   ap-northeast-1a = apne1-az4
#   ap-northeast-1c = apne1-az1
#   ap-northeast-1d = apne1-az2   <- the trading host is here today

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # Local state on purpose: a scratch stack must not touch the R2 backend.
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile
}

variable "region" {
  type    = string
  default = "ap-northeast-1"
}

variable "aws_profile" {
  type    = string
  default = "trading"
}

variable "zones" {
  description = "Zone IDs to compare. Names are account aliases, IDs are not."
  type        = list(string)
  default     = ["apne1-az4", "apne1-az1", "apne1-az2"]
}

variable "instance_type" {
  description = "Must match the production host: network behaviour varies by instance family, so a c7g.medium probe would not predict a c7g.2xlarge host."
  type        = string
  default     = "c7g.2xlarge"
}

variable "ssh_private_key_file" {
  description = "Private key on the laptop; its .pub half is what the probes get."
  type        = string
  default     = "~/.ssh/id_ed25519_trading"
}

variable "ssh_allowed_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}

locals {
  name = "az-probe"
  # 10.30/16: outside the trading VPC's 10.20/16, so the two can never collide.
  subnets = { for i, z in var.zones : z => cidrsubnet("10.30.0.0/16", 8, i) }
}

resource "aws_vpc" "probe" {
  cidr_block           = "10.30.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = local.name }
}

resource "aws_internet_gateway" "probe" {
  vpc_id = aws_vpc.probe.id
  tags   = { Name = local.name }
}

resource "aws_route_table" "probe" {
  vpc_id = aws_vpc.probe.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.probe.id
  }
  tags = { Name = local.name }
}

resource "aws_subnet" "probe" {
  for_each = local.subnets

  vpc_id = aws_vpc.probe.id
  # By ID, not by name: this is the whole experiment.
  availability_zone_id    = each.key
  cidr_block              = each.value
  map_public_ip_on_launch = true

  tags = { Name = "${local.name}-${each.key}" }
}

resource "aws_route_table_association" "probe" {
  for_each = aws_subnet.probe

  subnet_id      = each.value.id
  route_table_id = aws_route_table.probe.id
}

resource "aws_security_group" "probe" {
  name        = "${local.name}-sg"
  description = "ssh in, all out"
  vpc_id      = aws_vpc.probe.id
  tags        = { Name = local.name }
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each = toset(var.ssh_allowed_cidrs)

  security_group_id = aws_security_group.probe.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.probe.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_key_pair" "probe" {
  key_name   = "${local.name}-key"
  public_key = trimspace(file(pathexpand("${var.ssh_private_key_file}.pub")))
}

# The same image the trading host will run, so the probe doubles as a check
# that the Debian 13 arm64 AMI boots on this instance type.
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
}

resource "aws_instance" "probe" {
  for_each = aws_subnet.probe

  ami                         = data.aws_ami.debian13_arm64.id
  instance_type               = var.instance_type
  subnet_id                   = each.value.id
  vpc_security_group_ids      = [aws_security_group.probe.id]
  key_name                    = aws_key_pair.probe.key_name
  associate_public_ip_address = true
  # No termination protection: this stack exists to be destroyed.
  disable_api_termination = false

  root_block_device {
    volume_size = 10
    volume_type = "gp3"
  }

  tags = { Name = "${local.name}-${each.key}" }
}

output "probes" {
  description = "zone id -> public address to ssh to"
  value       = { for z, i in aws_instance.probe : z => i.public_ip }
}
