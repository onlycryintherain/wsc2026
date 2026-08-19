output "app_key_arn" {
  description = "ARN of App KMS key"
  value       = aws_kms_key.app.arn
}

output "data_key_arn" {
  description = "ARN of Data KMS key"
  value       = aws_kms_key.data.arn
}

output "platform_key_arn" {
  description = "ARN of Platform KMS key"
  value       = aws_kms_key.platform.arn
}

output "platform_replica_key_arn" {
  description = "ARN of Platform replica KMS key in us-east-1"
  value       = aws_kms_replica_key.platform_replica.arn
}

output "platform_key_id" {
  description = "Key ID of Platform KMS key"
  value       = aws_kms_key.platform.key_id
}
