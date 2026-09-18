output "instance_id" {
  value = aws_instance.host.id
}

output "ami" {
  description = "The image the host was launched from (pinned by lifecycle.ignore_changes)."
  value       = { id = aws_instance.host.ami, name = data.aws_ami.ubuntu_arm64.name }
}

output "public_ips" {
  description = "The elastic IPs, in the order of their private addresses."
  value       = [for i in range(var.elastic_ip_count) : aws_eip.host[i].public_ip]
}

output "addresses" {
  description = "elastic IP -> private address it is bound to (the last one on the hyperstream ENI when that exists)."
  value = {
    for i in range(var.elastic_ip_count) : aws_eip.host[i].public_ip => (
      i == local.hyperstream_eip_index ? aws_network_interface.hyperstream[0].private_ip : local.private_ips[i]
    )
  }
}

output "hyperstream_eni" {
  description = "The hyperstream ENI, when hyperstream_eni is set: what the OS binds to vfio-pci and what the producer is told about its address."
  value = var.hyperstream_eni ? {
    id         = aws_network_interface.hyperstream[0].id
    mac        = aws_network_interface.hyperstream[0].mac_address
    private_ip = aws_network_interface.hyperstream[0].private_ip
    public_ip  = aws_eip.host[local.hyperstream_eip_index].public_ip
    # The primary ENI address that EIP used to map to: no public mapping now;
    # drop it from the bot's `network` source addresses.
    unmapped_primary_private_ip = local.private_ips[local.hyperstream_eip_index]
  } : null
}

output "ssh_private_key_file" {
  value = var.ssh_private_key_file
}

output "ssh" {
  description = "How to reach the box as the image's own account (Ansible uses the same)."
  value       = "ssh ubuntu@${aws_eip.host[0].public_ip}"
}

# `just inventory` writes this to inventory/hosts.yml.
output "ansible_inventory" {
  value = <<-EOT
    # Generated from terraform output; do not edit (just inventory).
    all:
      hosts:
        ${var.name}:
          ansible_host: ${aws_eip.host[0].public_ip}
          ansible_user: ubuntu
          ansible_ssh_private_key_file: ${var.ssh_private_key_file}
          ansible_python_interpreter: /usr/bin/python3
          instance_id: ${aws_instance.host.id}
          availability_zone: ${var.availability_zone}
          elastic_ips: ${jsonencode([for i in range(var.elastic_ip_count) : aws_eip.host[i].public_ip])}
          hyperstream_eni_mac: ${var.hyperstream_eni ? jsonencode(aws_network_interface.hyperstream[0].mac_address) : "null"}
          hyperstream_eni_private_ip: ${var.hyperstream_eni ? jsonencode(aws_network_interface.hyperstream[0].private_ip) : "null"}
          hyperstream_public_ip: ${var.hyperstream_eni ? jsonencode(aws_eip.host[local.hyperstream_eip_index].public_ip) : "null"}
          # the same key goes to the trading-bot account (ansible vars.yml)
          ssh_public_key: ${jsonencode(var.ssh_public_key)}
  EOT
}
