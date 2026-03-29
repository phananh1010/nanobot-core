output "public_ip" {
  description = "Elastic IP address of the nanobot EC2 instance."
  value       = aws_eip.nanobot.public_ip
}

output "instance_id" {
  description = "EC2 instance ID."
  value       = aws_instance.nanobot.id
}

output "ssh_command" {
  description = "SSH command to connect to the instance."
  value       = "ssh ubuntu@${aws_eip.nanobot.public_ip}"
}

output "gateway_url" {
  description = "nanobot HTTP gateway endpoint."
  value       = var.domain_name != "" ? "https://${var.domain_name}" : "http://${aws_eip.nanobot.public_ip}:${var.gateway_port}"
}

output "health_check_url" {
  description = "Health check endpoint."
  value       = var.domain_name != "" ? "https://${var.domain_name}/health" : "http://${aws_eip.nanobot.public_ip}:${var.gateway_port}/health"
}

output "ssm_prefix" {
  description = "SSM Parameter Store path prefix used for secrets."
  value       = "/${var.project}"
}
