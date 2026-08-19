output "distribution_arn" {
  value = aws_cloudfront_distribution.this.arn
}

output "distribution_domain" {
  value = aws_cloudfront_distribution.this.domain_name
}
