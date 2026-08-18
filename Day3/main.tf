terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.60" }
    tls = { source = "hashicorp/tls", version = "~> 4.0" }
  }
}

provider "aws" {
  region = var.region
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}

resource "aws_cloudwatch_log_group" "waf" {
  provider          = aws.us_east_1
  name              = "aws-waf-logs-${var.cluster_name}"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_resource_policy" "waf" {
  provider    = aws.us_east_1
  policy_name = "${var.cluster_name}-waf-logging"
  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AWSWAFLogsToCloudWatch"
      Effect = "Allow"
      Principal = {
        Service = "wafv2.amazonaws.com"
      }
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.waf.arn}:*"
    }]
  })
}

variable "region" { default = "ap-northeast-2" }
variable "cluster_name" { default = "wsi2026-cluster" }
variable "db_identifier" { default = "apdev-rds-instance" }
variable "db_name" { default = "dev" }
variable "db_username" {
  type    = string
  default = "admin"
  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9_]{0,15}$", var.db_username))
    error_message = "db_username은 영문자로 시작하는 영숫자/밑줄 1~16자여야 합니다. 하이픈은 사용할 수 없습니다."
  }
}
variable "db_proxy_name" { default = "apdev-proxy" }
variable "db_secret_name" { default = "apdev-rds-credentials" }
variable "db_instance_class" { default = "db.t3.micro" }
variable "eks_node_instance_type" { default = "t3.medium" }
variable "db_password" {
  default   = "Skill53##"
  sensitive = true
}

# ===================
# VPC
# ===================
module "vpc" {
  source       = "./modules/vpc"
  cluster_name = var.cluster_name
}

# ===================
# EKS
# ===================
module "eks" {
  source        = "./modules/eks"
  cluster_name  = var.cluster_name
  vpc_id        = module.vpc.vpc_id
  vpc_cidr      = module.vpc.vpc_cidr
  subnet_ids    = module.vpc.public_subnet_ids
  instance_type = var.eks_node_instance_type
}

# ===================
# RDS + Proxy
# ===================
module "rds" {
  source         = "./modules/rds"
  cluster_name   = var.cluster_name
  vpc_id         = module.vpc.vpc_id
  vpc_cidr       = module.vpc.vpc_cidr
  subnet_ids     = module.vpc.public_subnet_ids
  db_password    = var.db_password
  identifier     = var.db_identifier
  db_name        = var.db_name
  username       = var.db_username
  proxy_name     = var.db_proxy_name
  secret_name    = var.db_secret_name
  instance_class = var.db_instance_class
}

# ===================
# WAF
# ===================
module "waf" {
  source       = "./modules/waf"
  cluster_name = var.cluster_name

  providers = {
    aws.us_east_1 = aws.us_east_1
  }
}

# ===================
# Karpenter
# ===================
module "karpenter" {
  source            = "./modules/karpenter"
  cluster_name      = var.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_url          = module.eks.oidc_url
}

# ===================
# S3 + ECR
# ===================
module "s3" {
  source               = "./modules/s3"
  cluster_name         = var.cluster_name
  source_path          = path.module
  oidc_provider_arn    = module.eks.oidc_provider_arn
  oidc_url             = module.eks.oidc_url
  region               = var.region
  account_id           = data.aws_caller_identity.current.account_id
  vpc_id               = module.vpc.vpc_id
  karpenter_role_arn   = module.karpenter.karpenter_role_arn
  karpenter_queue_name = module.karpenter.karpenter_queue_name
  node_role_name       = module.eks.node_role_name
  log_bucket           = ""
  db_identifier        = var.db_identifier
  db_name              = var.db_name
  db_username          = var.db_username
  db_secret_name       = var.db_secret_name
  db_proxy_name        = var.db_proxy_name
  node_instance_type   = var.eks_node_instance_type
}

resource "aws_ecr_repository" "apps" {
  for_each             = toset(["user", "product", "stress"])
  name                 = each.key
  image_tag_mutability = "MUTABLE"
  force_delete         = true
}

# ===================
# Bastion
# ===================
module "bastion" {
  source       = "./modules/bastion"
  cluster_name = var.cluster_name
  vpc_id       = module.vpc.vpc_id
  subnet_id    = module.vpc.public_subnet_ids[0]
  s3_bucket    = module.s3.bucket_name
  scripts_path = "${path.module}/scripts"

  depends_on = [
    module.s3,
    module.eks,
  ]
}

# ===================
# CloudWatch Alarms
# ===================
resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "apdev-rds-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "RDS CPU utilization exceeds 80%"

  dimensions = {
    DBInstanceIdentifier = var.db_identifier
  }
}

resource "aws_cloudwatch_metric_alarm" "eks_node_cpu" {
  alarm_name          = "apdev-eks-node-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "node_cpu_utilization"
  namespace           = "ContainerInsights"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "EKS node CPU utilization exceeds 80%"

  dimensions = {
    ClusterName = var.cluster_name
    NodeGroup   = "${var.cluster_name}-ng"
  }
}

# ===================
# Outputs
# ===================
output "rds_endpoint" {
  value = module.rds.rds_endpoint
}

output "rds_proxy_endpoint" {
  value = module.rds.rds_proxy_endpoint
}

output "s3_bucket" {
  value = module.s3.bucket_name
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "bastion_ip" {
  value = module.bastion.bastion_ip
}

output "waf_log_group" {
  value = "aws-waf-logs-${var.cluster_name}"
}

output "waf_log_region" {
  value = "us-east-1"
}
