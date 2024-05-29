output "public_ip" {
  value = aws_instance.instance.public_ip
}

output "url" {
  value = "https://${var.tfe_hostname}"
}

output "ssh_connect" {
    value = "ssh -i ${var.key_pair}.pem ec2-user@${aws_instance.instance.public_ip}"
}