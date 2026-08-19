output "vpc_id" {
  value = module.VPC.vpc_id
}

output "ecr_repository_url" {
  value = module.ECR.repository_url
}

output "alb_dns_name" {
  value = module.ALB.alb_dns_name
}

output "cloudfront_domain" {
  value = module.CloudFront.distribution_domain
}

output "s3_bucket_name" {
  value = module.S3.bucket_id
}

output "private_subnet_ids" {
  value = module.VPC.private_subnet_ids
}

output "platform_key_arn" {
  value = module.KMS.platform_key_arn
}


output "bastion_public_ip" {
  value = aws_eip.bastion.public_ip
}
