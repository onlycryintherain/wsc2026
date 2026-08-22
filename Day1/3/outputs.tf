output "cloudfront_domain" {
  value = aws_cloudfront_distribution.cdn.domain_name
}

output "cloudfront_id" {
  value = aws_cloudfront_distribution.cdn.id
}

output "bastion_ip" {
  value = aws_eip.bastion.public_ip
}

output "lambda_arn" {
  value = aws_lambda_function.book_get.arn
}
