output "bastion_ip" {
  value = aws_instance.bastion.public_ip
}

output "bastion_role_arn" {
  value = aws_iam_role.bastion.arn
}
