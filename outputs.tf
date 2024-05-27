output "public_ip" {
  value = aws_instance.instance.public_ip
}

output "url" {
  value = "https://${var.tfe_hostname}"
}

output "ssh_connect" {
    value = "ssh -i ${var.key_pair}.pem ubuntu@${aws_instance.instance.public_ip}"
}