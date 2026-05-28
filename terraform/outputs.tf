output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.node.id
}

output "region" {
  description = "AWS region the node was created in"
  value       = var.region
}

output "public_ip" {
  description = "Public IP (used only for K8s API/UI later if needed; SSH is closed)"
  value       = aws_instance.node.public_ip
}

output "ssm_command" {
  description = "Copy-paste this to start a Session Manager shell on the node"
  value       = "aws ssm start-session --target ${aws_instance.node.id} --region ${var.region}"
}

output "tail_bootstrap_log" {
  description = "Once connected via SSM, run this to follow the user_data bootstrap log"
  value       = "sudo tail -f /var/log/user-data.log"
}
