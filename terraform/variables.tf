variable "region" {
  description = "AWS region. Tokyo: the venues' matching engines are there."
  type        = string
  default     = "ap-northeast-1"
}

variable "availability_zone" {
  description = "AZ for the subnet and the instance (c7g is offered in ap-northeast-1a, 1c and 1d)."
  type        = string
  default     = "ap-northeast-1a"
}

variable "aws_profile" {
  description = "Named profile in ~/.aws/credentials to use; null = the default credential chain (env vars, SSO, instance role)."
  type        = string
  default     = null
}

variable "name" {
  description = "Name prefix for every resource, and the instance's Name tag."
  type        = string
  default     = "trading-host"
}

variable "instance_type" {
  description = "Graviton instance type. c7g.2xlarge: 8 vCPU (no SMT), 16 GiB, up to 15 Gbit/s."
  type        = string
  default     = "c7g.2xlarge"
}

variable "root_volume_gb" {
  description = "Root volume size in GiB (gp3, encrypted). Debian grows the filesystem into it at first boot."
  type        = number
  default     = 80
}

variable "elastic_ip_count" {
  description = "How many elastic IPs to attach. Each one is bound to its own private address on the primary ENI, so the bot can use them as distinct source IPs."
  type        = number
  default     = 3

  validation {
    condition     = var.elastic_ip_count >= 1 && var.elastic_ip_count <= 15
    error_message = "1 to 15 (a single ENI on c7g.2xlarge carries at most 15 IPv4 addresses)."
  }
}

variable "ssh_allowed_cidrs" {
  description = "CIDRs allowed to reach port 22, the only inbound rule. The operator's laptop has no fixed address, so the default is the whole internet; sshd is key-only and CrowdSec bans brute-forcers at the host firewall (ansible role crowdsec). Narrow it to /32s if you ever get a fixed address."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = length(var.ssh_allowed_cidrs) > 0
    error_message = "Give at least one CIDR."
  }
}

variable "ssh_public_key" {
  description = "The one OpenSSH public key for the box: the AMI's built-in 'admin' user gets it at launch (Ansible logs in with it), and Ansible gives it to the trading-bot account. One line, 'ssh-ed25519 AAAA... comment'."
  type        = string

  validation {
    condition     = can(regex("^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp[0-9]+|sk-[a-z0-9-]+@openssh.com) [A-Za-z0-9+/=]+", var.ssh_public_key))
    error_message = "Not an OpenSSH public key line."
  }
}

variable "vpc_cidr" {
  description = "CIDR of the dedicated VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR of the single public subnet."
  type        = string
  default     = "10.20.1.0/24"
}

variable "termination_protection" {
  description = "Refuse API termination of the instance (a `terraform destroy` must first flip this to false and apply). On by default: this box holds state and keys."
  type        = bool
  default     = true
}
