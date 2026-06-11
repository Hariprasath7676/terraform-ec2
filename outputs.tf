output "instance_id" {
  value = aws_instance.server.id
}

output "private_ip" {
  value = aws_instance.server.private_ip
}

output "security_group_id" {
  value = aws_security_group.server.id
}

output "pem_location" {
  value = "s3://${var.s3_bucket}/${var.s3_key_path}/${var.key_name}.pem"
}
