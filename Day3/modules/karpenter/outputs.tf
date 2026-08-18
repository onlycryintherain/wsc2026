output "karpenter_role_arn" {
  value = aws_iam_role.karpenter.arn
}

output "karpenter_queue_name" {
  value = aws_sqs_queue.karpenter.name
}
