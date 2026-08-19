data "aws_caller_identity" "current" {}

resource "aws_kms_key" "db" {
  description             = "KMS key for wskorea26 DynamoDB"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  tags                    = { Name = "wskorea26-dynamodb-key" }
}

resource "aws_kms_alias" "db" {
  name          = var.db_key_alias
  target_key_id = aws_kms_key.db.key_id
}

resource "aws_kms_key" "s3" {
  description             = "KMS key for wskorea26 S3"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccount"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowCloudFrontService"
        Effect    = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action    = ["kms:Decrypt", "kms:GenerateDataKey*"]
        Resource  = "*"
      }
    ]
  })

  tags = { Name = "wskorea26-s3-key" }
}

resource "aws_kms_alias" "s3" {
  name          = var.s3_key_alias
  target_key_id = aws_kms_key.s3.key_id
}

resource "aws_kms_key" "eks" {
  description             = "KMS key for wskorea26 EKS secrets"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  tags                    = { Name = "wskorea26-eks-key" }
}

resource "aws_kms_alias" "eks" {
  name          = var.eks_key_alias
  target_key_id = aws_kms_key.eks.key_id
}
