output "instance_id" {
  value = aws_instance.host.id
}

output "ami" {
  description = "The Debian image the host was launched from (pinned by lifecycle.ignore_changes)."
  value       = { id = aws_instance.host.ami, name = data.aws_ami.debian13_arm64.name }
}

output "public_ips" {
  description = "The elastic IPs, in the order of their private addresses."
  value       = [for i in range(var.elastic_ip_count) : aws_eip.host[i].public_ip]
}

output "addresses" {
  description = "elastic IP -> private address it is bound to on the ENI."
  value       = { for i in range(var.elastic_ip_count) : aws_eip.host[i].public_ip => local.private_ips[i] }
}

output "ssh" {
  description = "How to reach the box as the AMI's admin user (Ansible uses the same)."
  value       = "ssh admin@${aws_eip.host[0].public_ip}"
}

# `just inventory` writes this to ansible/inventory/hosts.yml.
output "ansible_inventory" {
  value = <<-EOT
    # Generated from terraform output; do not edit (just inventory).
    all:
      hosts:
        ${var.name}:
          ansible_host: ${aws_eip.host[0].public_ip}
          ansible_user: admin
          ansible_python_interpreter: /usr/bin/python3
          instance_id: ${aws_instance.host.id}
          elastic_ips: ${jsonencode([for i in range(var.elastic_ip_count) : aws_eip.host[i].public_ip])}
  EOT
}
