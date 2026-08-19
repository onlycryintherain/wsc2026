output "vpc_id" { value = module.VPC.vpc_id }
output "ecr_repository_url" { value = module.ECR.repository_url }
output "cloudfront_domain" { value = module.CloudFront.domain_name }
output "book_ingress_alb_name" { value = "wskorea26-book-alb" }
output "grafana_ingress_alb_name" { value = "wskorea26-grafana-alb" }
output "ingress_api_origin_domain_name" { value = var.ingress_api_origin_domain_name }
output "manifest_bucket" { value = aws_s3_bucket.manifest.id }
