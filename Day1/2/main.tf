terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = "ap-northeast-2"
}

variable "pin_number" {
  description = "비번호 (PIN)"
  type        = string
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

module "VPC" {
  source                = "./modules/VPC"
  vpc_name              = "wskorea26-vpc"
  vpc_cidr              = "172.16.0.0/16"
  public_subnets_cidr   = ["172.16.1.0/24", "172.16.2.0/24"]
  isolated_subnets_cidr = ["172.16.201.0/24", "172.16.202.0/24"]
  availability_zones    = ["ap-northeast-2c", "ap-northeast-2d"]
  public_subnet_names   = ["wskorea26-pub-subnet-c", "wskorea26-pub-subnet-d"]
  isolated_subnet_names = ["wskorea26-priv-subnet-c", "wskorea26-priv-subnet-d"]
}

module "KMS" {
  source        = "./modules/KMS"
  db_key_alias  = "alias/wskorea26-dynamodb-key"
  s3_key_alias  = "alias/wskorea26-s3-key"
  eks_key_alias = "alias/wskorea26-eks-key"
}

module "DynamoDB" {
  source      = "./modules/DynamoDB"
  table_name  = "wskorea26-data-table"
  hash_key    = "client_id"
  kms_key_arn = module.KMS.db_key_arn
}

module "S3" {
  source      = "./modules/S3"
  bucket_name = "wskorea26-concert-bucket-${var.pin_number}"
  kms_key_arn = module.KMS.s3_key_arn
}

module "ECR" {
  source          = "./modules/ECR"
  repository_name = "wskorea26-book-repo"
}

resource "aws_iam_role" "book_app" {
  name_prefix = "wskorea26-book-app-role-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/oidc.eks.ap-northeast-2.amazonaws.com/id/OIDC_ID" }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "oidc.eks.ap-northeast-2.amazonaws.com/id/OIDC_ID:sub" = "system:serviceaccount:wskorea26:book-sa"
          "oidc.eks.ap-northeast-2.amazonaws.com/id/OIDC_ID:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
  lifecycle {
    ignore_changes = [assume_role_policy]
  }
}

resource "aws_iam_role_policy" "book_app" {
  name = "wskorea26-book-app-policy"
  role = aws_iam_role.book_app.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:Query", "dynamodb:Scan"]
        Resource = [module.DynamoDB.table_arn, "${module.DynamoDB.table_arn}/index/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:Encrypt", "kms:DescribeKey"]
        Resource = module.KMS.db_key_arn
      }
    ]
  })
}

data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.root}/lambda/book_lambda.py"
  output_path = "${path.root}/lambda/book_lambda.zip"
}

resource "aws_iam_role" "lambda" {
  name_prefix = "wskorea26-book-lambda-role-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda" {
  name = "wskorea26-book-lambda-policy"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:Query"]
        Resource = [module.DynamoDB.table_arn, "${module.DynamoDB.table_arn}/index/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:DescribeKey"]
        Resource = module.KMS.db_key_arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:*"
      }
    ]
  })
}

resource "aws_lambda_function" "book" {
  function_name    = "wskorea26-book-lambda"
  role             = aws_iam_role.lambda.arn
  handler          = "book_lambda.handler"
  runtime          = "python3.14"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 10

  environment {
    variables = {
      TABLE_NAME = module.DynamoDB.table_name
      INDEX_NAME = "concert_name-created_at-index"
    }
  }
}

resource "aws_lambda_permission" "alb" {
  statement_id  = "AllowExecutionFromALB"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.book.function_name
  principal     = "elasticloadbalancing.amazonaws.com"
  source_arn    = aws_lb_target_group.lambda.arn
}

# ALB resources are managed by AWS Load Balancer Controller Ingress.
# The Lambda target group remains because the GET /book Ingress action forwards to it.
resource "aws_lb_target_group" "lambda" {
  name        = "wskorea26-book-lambda-tg"
  target_type = "lambda"
}

resource "aws_lb_target_group_attachment" "lambda" {
  target_group_arn = aws_lb_target_group.lambda.arn
  target_id        = aws_lambda_function.book.arn
  depends_on       = [aws_lambda_permission.alb]
}

resource "aws_security_group" "vpc_environment" {
  name   = "wskorea26-vpc-environment-sg"
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

  tags = { Name = "wskorea26-vpc-environment-sg" }
}

data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-*-x86_64"]
  }
}

resource "aws_security_group" "bastion" {
  name   = "wskorea26-bastion-sg"
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

  tags = { Name = "wskorea26-bastion-sg" }
}

resource "aws_iam_role" "bastion" {
  name = "wskorea26-bastion-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "bastion" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "wskorea26-bastion-profile"
  role = aws_iam_role.bastion.name
}

resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.amazon_linux_2023.id
  instance_type               = "t3.medium"
  subnet_id                   = module.VPC.public_subnet_ids[0]
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  iam_instance_profile        = aws_iam_instance_profile.bastion.name
  associate_public_ip_address = true

  user_data = <<-EOF
#!/bin/bash
set -e
export REGION=ap-northeast-2
export AWS_PAGER=""
BUCKET=$(aws s3 ls --region $REGION | awk '/wskorea26-manifest-/ {print $3; exit}')
cd /home/ec2-user
aws s3 cp s3://$BUCKET/ . --recursive --region $REGION
sed -i 's/\r$//' *.sh *.yaml *.yml 2>/dev/null || true
chmod +x setup.sh
chown -R ec2-user:ec2-user /home/ec2-user
EOF

  tags = { Name = "wskorea26-bastion" }

  depends_on = [aws_s3_object.manifests, aws_s3_object.book_binary]
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/wskorea26/application"
  retention_in_days = 7
  tags              = { Name = "/wskorea26/application" }
}

resource "aws_s3_bucket" "manifest" {
  bucket_prefix = "wskorea26-manifest-"
  force_destroy = true
}

resource "aws_s3_object" "manifests" {
  for_each = { for f in fileset("${path.root}/manifest", "*") : f => f if !contains(["grafana-values.yaml", "serviceaccount.yaml"], f) }
  bucket   = aws_s3_bucket.manifest.id
  key      = each.value
  source   = "${path.root}/manifest/${each.value}"
  etag     = filemd5("${path.root}/manifest/${each.value}")
}

resource "aws_s3_object" "grafana_values" {
  bucket = aws_s3_bucket.manifest.id
  key    = "grafana-values.yaml"
  content = templatefile("${path.root}/manifest/grafana-values.yaml", {
    pin_number = var.pin_number
  })
}

resource "aws_s3_object" "serviceaccount" {
  bucket = aws_s3_bucket.manifest.id
  key    = "serviceaccount.yaml"
  content = templatefile("${path.root}/manifest/serviceaccount.yaml", {
    book_app_role_arn = aws_iam_role.book_app.arn
  })
}





resource "aws_s3_object" "book_binary" {
  bucket = aws_s3_bucket.manifest.id
  key    = "book"
  source = "${path.root}/배포파일/book"
  etag   = filemd5("${path.root}/배포파일/book")
}

resource "aws_s3_object" "index_html_manifest" {
  bucket = aws_s3_bucket.manifest.id
  key    = "index.html"
  source = "${path.root}/배포파일/index.html"
  etag   = filemd5("${path.root}/배포파일/index.html")
}

resource "aws_s3_object" "main_jpeg_manifest" {
  bucket = aws_s3_bucket.manifest.id
  key    = "main.jpeg"
  source = "${path.root}/배포파일/main.jpeg"
  etag   = filemd5("${path.root}/배포파일/main.jpeg")
}

resource "aws_s3_object" "index_html" {
  bucket                 = module.S3.bucket_id
  key                    = "web/main/index.html"
  source                 = "${path.root}/배포파일/index.html"
  server_side_encryption = "aws:kms"
  kms_key_id             = module.KMS.s3_key_arn
  content_type           = "text/html"
}

resource "aws_s3_object" "main_jpeg" {
  bucket                 = module.S3.bucket_id
  key                    = "web/main/main.jpeg"
  source                 = "${path.root}/배포파일/main.jpeg"
  server_side_encryption = "aws:kms"
  kms_key_id             = module.KMS.s3_key_arn
  content_type           = "image/jpeg"
}

module "CloudFront" {
  source                         = "./modules/CloudFront"
  distribution_name              = "wskorea26-concert-cf"
  oac_name                       = "wskorea26-s3-oac"
  s3_origin_id                   = "wskorea26-s3-origin"
  alb_origin_id                  = "wskorea26-alb-origin"
  api_origin_enabled             = var.ingress_api_origin_enabled
  api_origin_domain_name         = var.ingress_api_origin_domain_name
  s3_bucket_id                   = module.S3.bucket_id
  s3_bucket_arn                  = module.S3.bucket_arn
  s3_bucket_regional_domain_name = module.S3.bucket_regional_domain_name
}
