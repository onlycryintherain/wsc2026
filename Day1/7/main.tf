terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

variable "number" {
  description = "선수 비번호"
  type        = string
}

provider "aws" {
  region = "ap-northeast-2"
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}

# ========== VPC ==========
module "VPC" {
  source               = "./modules/VPC"
  vpc_name             = "unicorn-vpc"
  vpc_cidr             = "10.97.0.0/16"
  public_subnets_cidr  = ["10.97.0.0/24", "10.97.1.0/24", "10.97.2.0/24"]
  private_subnets_cidr = ["10.97.10.0/24", "10.97.11.0/24", "10.97.12.0/24"]
  availability_zones   = ["ap-northeast-2a", "ap-northeast-2b", "ap-northeast-2c"]
  public_subnet_names  = ["unicorn-subnet-pub-a", "unicorn-subnet-pub-b", "unicorn-subnet-pub-c"]
  private_subnet_names = ["unicorn-subnet-priv-a", "unicorn-subnet-priv-b", "unicorn-subnet-priv-c"]
  igw_name             = "unicorn-igw"
  nat_eip_names        = ["unicorn-eip-nat-a", "unicorn-eip-nat-b", "unicorn-eip-nat-c"]
  nat_gw_names         = ["unicorn-nat-a", "unicorn-nat-b", "unicorn-nat-c"]
  public_rt_name       = "unicorn-rt-pub"
  private_rt_names     = ["unicorn-rt-priv-a", "unicorn-rt-priv-b", "unicorn-rt-priv-c"]
  flow_log_name        = "unicorn-flow-log"
}

# ========== KMS ==========
module "KMS" {
  source             = "./modules/KMS"
  app_key_alias      = "alias/unicorn-kms-app"
  data_key_alias     = "alias/unicorn-kms-data"
  platform_key_alias = "alias/unicorn-kms-platform"
  rotation_period    = 90

  providers = {
    aws.us_east_1 = aws.us_east_1
  }
}

# ========== S3 ==========
module "S3" {
  source      = "./modules/S3"
  bucket_name = "unicorn-web-${data.aws_caller_identity.current.account_id}"
  kms_key_arn = module.KMS.data_key_arn
}

# ========== DynamoDB ==========
module "DynamoDB" {
  source         = "./modules/DynamoDB"
  table_name     = "unicorn-concert-db"
  kms_key_arn    = module.KMS.app_key_arn
  hash_key       = "booking_id"
  gsi_name       = "client-id-created-at-index"
  gsi_hash_key   = "client_id"
  gsi_range_key  = "created_at"
  gsi_projection = "ALL"
}

# ========== ECR ==========
module "ECR" {
  source          = "./modules/ECR"
  repository_name = "unicorn-concert-app"
  kms_key_arn     = module.KMS.data_key_arn
}

# ========== ECR Image Build & Push (done in CloudShell via apply.sh) ==========
# IMMUTABLE_WITH_EXCLUSION also set in apply.sh

# ========== EKS + K8s (manual via eksctl + kubectl) ==========
# 1. eksctl create cluster -f manifest/cluster.yaml
# 2. kubectl apply -f manifest/

# ========== EKS Pod Identity Role ==========
resource "aws_iam_role" "book_app" {
  name = "unicorn-book-app-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Condition = {
        ArnEquals = {
          "aws:SourceArn" = "arn:aws:eks:ap-northeast-2:${data.aws_caller_identity.current.account_id}:cluster/unicorn-eks-cluster"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "book_app" {
  name = "unicorn-book-app-policy"
  role = aws_iam_role.book_app.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:Query"]
        Resource = [module.DynamoDB.table_arn, "${module.DynamoDB.table_arn}/index/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey"]
        Resource = [module.KMS.app_key_arn]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogGroups", "logs:DescribeLogStreams"]
        Resource = ["arn:aws:logs:ap-northeast-2:${data.aws_caller_identity.current.account_id}:*"]
      }
    ]
  })
}

resource "aws_eks_pod_identity_association" "book_app" {
  count           = 0 # Created after EKS exists
  cluster_name    = "unicorn-eks-cluster"
  namespace       = "unicorn"
  service_account = "unicorn-book-app-sa"
  role_arn        = aws_iam_role.book_app.arn
}

# ========== Lambda ==========
module "Lambda" {
  source             = "./modules/Lambda"
  function_name      = "unicorn-get-booking-func"
  kms_key_arn        = module.KMS.platform_key_arn
  table_name         = module.DynamoDB.table_name
  table_arn          = module.DynamoDB.table_arn
  log_group_name     = "/unicorn/lambda/get-booking"
  private_subnet_ids = module.VPC.private_subnet_ids
  vpc_id             = module.VPC.vpc_id
}

# ========== ALB ==========
module "ALB" {
  source             = "./modules/ALB"
  alb_name           = "unicorn-alb"
  tg_name            = "unicorn-tg"
  vpc_id             = module.VPC.vpc_id
  private_subnet_ids = module.VPC.private_subnet_ids
  lambda_arn         = module.Lambda.function_arn
  lambda_invoke_arn  = module.Lambda.invoke_arn
}

# ========== CloudFront + WAF ==========
module "CloudFront" {
  source               = "./modules/CloudFront"
  distribution_comment = "unicorn-svc-cf"
  s3_bucket_id         = module.S3.bucket_id
  s3_bucket_arn        = module.S3.bucket_arn
  alb_arn              = module.ALB.alb_arn
  alb_dns_name         = module.ALB.alb_dns_name
  waf_name             = "unicorn-waf"
  kms_key_arn          = module.KMS.platform_replica_key_arn
  vpc_id               = module.VPC.vpc_id
  alb_sg_id            = module.ALB.alb_sg_id
  private_subnet_ids   = module.VPC.private_subnet_ids

  providers = {
    aws.us_east_1 = aws.us_east_1
  }
}

# ========== IAM Audit Role ==========
module "IAM" {
  source             = "./modules/IAM"
  role_name          = "unicorn-audit-role"
  external_id        = "unicorn-audit-2026${var.number}"
  dynamodb_table_arn = module.DynamoDB.table_arn
  vpc_id             = module.VPC.vpc_id
  eks_cluster_arn    = "arn:aws:eks:ap-northeast-2:${data.aws_caller_identity.current.account_id}:cluster/unicorn-eks-cluster"
}

# ========== Grafana ALB ==========
resource "aws_lb" "grafana" {
  name               = "unicorn-grafana-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.grafana_alb.id]
  subnets            = module.VPC.public_subnet_ids

  tags = { Name = "unicorn-grafana-alb" }
}

resource "aws_security_group" "grafana_alb" {
  name   = "unicorn-grafana-alb-sg"
  vpc_id = module.VPC.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "unicorn-grafana-alb-sg" }
}

resource "aws_lb_target_group" "grafana" {
  name        = "unicorn-grafana-tg"
  port        = 30300
  protocol    = "HTTP"
  vpc_id      = module.VPC.vpc_id
  target_type = "instance"

  health_check {
    path     = "/api/health"
    protocol = "HTTP"
    port     = "30300"
  }
  tags = { Name = "unicorn-grafana-tg" }
}

resource "aws_lb_listener" "grafana" {
  load_balancer_arn = aws_lb.grafana.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.grafana.arn
  }
}

# ========== CloudWatch Log Groups ==========
resource "aws_cloudwatch_log_group" "book_app" {
  name       = "/unicorn/eks/book-app"
  kms_key_id = module.KMS.platform_key_arn
  tags       = { Name = "/unicorn/eks/book-app" }
}

# ========== Manifest S3 Bucket ==========
resource "aws_s3_bucket" "manifest" {
  bucket_prefix = "unicorn-manifest-"
  force_destroy = true
}

resource "aws_s3_object" "manifests" {
  for_each = { for f in fileset("${path.root}/manifest", "*") : f => f if f != "apply.sh" }
  bucket   = aws_s3_bucket.manifest.id
  key      = each.value
  source   = "${path.root}/manifest/${each.value}"
  etag     = filemd5("${path.root}/manifest/${each.value}")
}

resource "aws_s3_object" "apply_sh" {
  bucket  = aws_s3_bucket.manifest.id
  key     = "apply.sh"
  content = replace(file("${path.root}/manifest/apply.sh"), "NUMBER:-103", "NUMBER:-${var.number}")
}

resource "aws_s3_object" "book_binary" {
  bucket = aws_s3_bucket.manifest.id
  key    = "book"
  source = "${path.root}/docker/book"
  etag   = filemd5("${path.root}/docker/book")
}

resource "aws_s3_object" "dockerfile" {
  bucket = aws_s3_bucket.manifest.id
  key    = "Dockerfile"
  source = "${path.root}/docker/Dockerfile"
  etag   = filemd5("${path.root}/docker/Dockerfile")
}

# ========== CloudShell VPC Environment ==========
resource "aws_security_group" "cloudshell" {
  name   = "unicorn-mark-sg"
  vpc_id = module.VPC.vpc_id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "unicorn-mark-sg" }
}

# ========== Bastion ==========
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.1-x86_64"]
  }
}

resource "aws_iam_role" "bastion" {
  name = "unicorn-bastion-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "bastion" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "unicorn-bastion-profile"
  role = aws_iam_role.bastion.name
}

resource "aws_security_group" "bastion" {
  name   = "unicorn-bastion-sg"
  vpc_id = module.VPC.vpc_id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "unicorn-bastion-sg" }
}

resource "aws_instance" "bastion" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.medium"
  subnet_id              = module.VPC.public_subnet_ids[0]
  vpc_security_group_ids = [aws_security_group.bastion.id]
  iam_instance_profile   = aws_iam_instance_profile.bastion.name

  user_data = <<-EOF
#!/bin/bash
echo 'ec2-user:Skill53##' | chpasswd
sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
systemctl restart sshd
yum install -y docker
systemctl enable --now docker
usermod -aG docker ec2-user

# kubectl
curl -O https://s3.us-west-2.amazonaws.com/amazon-eks/1.33.0/2025-05-01/bin/linux/amd64/kubectl
chmod +x kubectl && mv kubectl /usr/bin/

# eksctl
curl -sL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" | tar xz -C /tmp && mv /tmp/eksctl /usr/bin/

# helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Download from S3
aws s3 cp s3://${aws_s3_bucket.manifest.id}/ /home/ec2-user/ --recursive --region ap-northeast-2
chown -R ec2-user:ec2-user /home/ec2-user/
chmod +x /home/ec2-user/apply.sh /home/ec2-user/book
EOF

  tags = { Name = "unicorn-bastion" }

  depends_on = [aws_s3_object.manifests, aws_s3_object.book_binary, aws_s3_object.dockerfile]
}

resource "aws_eip" "bastion" {
  instance = aws_instance.bastion.id
  domain   = "vpc"
  tags     = { Name = "unicorn-bastion-eip" }
}



# ========== EKS SG Rule (apply after EKS exists) ==========
# aws ec2 authorize-security-group-ingress --group-id <EKS_CLUSTER_SG> --protocol -1 --port -1 --source-group <cloudshell_sg_id>
# data "aws_eks_cluster" "this" {
#   name = "unicorn-eks-cluster"
# }
# resource "aws_security_group_rule" "eks_from_cloudshell" { ... }
