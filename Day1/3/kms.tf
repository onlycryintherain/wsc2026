data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = "ap-northeast-2"
}

# ============================================================
# DynamoDB KMS
# ============================================================
resource "aws_kms_key" "db" {
  description             = "wsc2026-db-kms"
  enable_key_rotation     = true
  deletion_window_in_days = 7

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "wsc2026-db-kms-policy"
    Statement = [
      {
        Sid    = "AllowKeyManagement"
        Effect = "Allow"
        Principal = {
          AWS = data.aws_caller_identity.current.arn
        }
        Action = [
          "kms:Create*", "kms:Describe*", "kms:Enable*", "kms:List*",
          "kms:Put*", "kms:Update*", "kms:Revoke*", "kms:Disable*",
          "kms:Get*", "kms:Delete*", "kms:TagResource", "kms:UntagResource",
          "kms:ScheduleKeyDeletion", "kms:CancelKeyDeletion",
          "kms:GenerateDataKey", "kms:Encrypt", "kms:Decrypt"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowAppRoles"
        Effect = "Allow"
        Principal = {
          AWS = [
            "arn:aws:iam::${local.account_id}:role/wsc2026-book-pod-role",
            "arn:aws:iam::${local.account_id}:role/wsc2026-book-function-role"
          ]
        }
        Action = [
          "kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowDynamoDBService"
        Effect = "Allow"
        Principal = {
          Service = "dynamodb.amazonaws.com"
        }
        Action = [
          "kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*",
          "kms:GenerateDataKey*", "kms:DescribeKey", "kms:CreateGrant"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:CallerAccount" = local.account_id
            "kms:ViaService"    = "dynamodb.${local.region}.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = { Name = "wsc2026-db-kms" }
}

resource "aws_kms_alias" "db" {
  name          = "alias/wsc2026-db-kms"
  target_key_id = aws_kms_key.db.key_id
}

# ============================================================
# ECR KMS
# ============================================================
resource "aws_kms_key" "ecr" {
  description             = "wsc2026-ecr-kms"
  enable_key_rotation     = true
  deletion_window_in_days = 7

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "wsc2026-ecr-kms-policy"
    Statement = [
      {
        Sid    = "AllowKeyManagement"
        Effect = "Allow"
        Principal = {
          AWS = data.aws_caller_identity.current.arn
        }
        Action = [
          "kms:Create*", "kms:Describe*", "kms:Enable*", "kms:List*",
          "kms:Put*", "kms:Update*", "kms:Revoke*", "kms:Disable*",
          "kms:Get*", "kms:Delete*", "kms:TagResource", "kms:UntagResource",
          "kms:ScheduleKeyDeletion", "kms:CancelKeyDeletion",
          "kms:GenerateDataKey", "kms:Encrypt", "kms:Decrypt"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowECRService"
        Effect = "Allow"
        Principal = {
          Service = "ecr.amazonaws.com"
        }
        Action = [
          "kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*",
          "kms:GenerateDataKey*", "kms:DescribeKey", "kms:CreateGrant"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:CallerAccount" = local.account_id
            "kms:ViaService"    = "ecr.${local.region}.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = { Name = "wsc2026-ecr-kms" }
}

resource "aws_kms_alias" "ecr" {
  name          = "alias/wsc2026-ecr-kms"
  target_key_id = aws_kms_key.ecr.key_id
}

# ============================================================
# EKS KMS
# ============================================================
resource "aws_kms_key" "eks" {
  description             = "wsc2026-eks-kms"
  enable_key_rotation     = true
  deletion_window_in_days = 7

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "wsc2026-eks-kms-policy"
    Statement = [
      {
        Sid    = "AllowKeyManagement"
        Effect = "Allow"
        Principal = {
          AWS = data.aws_caller_identity.current.arn
        }
        Action = [
          "kms:Create*", "kms:Describe*", "kms:Enable*", "kms:List*",
          "kms:Put*", "kms:Update*", "kms:Revoke*", "kms:Disable*",
          "kms:Get*", "kms:Delete*", "kms:TagResource", "kms:UntagResource",
          "kms:ScheduleKeyDeletion", "kms:CancelKeyDeletion",
          "kms:GenerateDataKey", "kms:Encrypt", "kms:Decrypt"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowEKSService"
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
        Action = [
          "kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*",
          "kms:GenerateDataKey*", "kms:DescribeKey", "kms:CreateGrant"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:CallerAccount" = local.account_id
            "kms:ViaService"    = "eks.${local.region}.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = { Name = "wsc2026-eks-kms" }
}

resource "aws_kms_alias" "eks" {
  name          = "alias/wsc2026-eks-kms"
  target_key_id = aws_kms_key.eks.key_id
}

# ============================================================
# S3 KMS
# ============================================================
resource "aws_kms_key" "bucket" {
  description             = "wsc2026-bucket-kms"
  enable_key_rotation     = true
  deletion_window_in_days = 7

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "wsc2026-bucket-kms-policy"
    Statement = [
      {
        Sid    = "AllowKeyManagement"
        Effect = "Allow"
        Principal = {
          AWS = data.aws_caller_identity.current.arn
        }
        Action = [
          "kms:Create*", "kms:Describe*", "kms:Enable*", "kms:List*",
          "kms:Put*", "kms:Update*", "kms:Revoke*", "kms:Disable*",
          "kms:Get*", "kms:Delete*", "kms:TagResource", "kms:UntagResource",
          "kms:ScheduleKeyDeletion", "kms:CancelKeyDeletion",
          "kms:GenerateDataKey", "kms:Encrypt", "kms:Decrypt"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowS3Service"
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
        Action = [
          "kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*",
          "kms:GenerateDataKey*", "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:CallerAccount" = local.account_id
            "kms:ViaService"    = "s3.${local.region}.amazonaws.com"
          }
        }
      },
      {
        Sid    = "AllowCloudFrontDecrypt"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action = [
          "kms:Decrypt", "kms:GenerateDataKey*"
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "AWS:SourceArn" = "arn:aws:cloudfront::${local.account_id}:distribution/*"
          }
        }
      }
    ]
  })

  tags = { Name = "wsc2026-bucket-kms" }
}

resource "aws_kms_alias" "bucket" {
  name          = "alias/wsc2026-bucket-kms"
  target_key_id = aws_kms_key.bucket.key_id
}

# ============================================================
# Lambda KMS
# ============================================================
resource "aws_kms_key" "function" {
  description             = "wsc2026-function-kms"
  enable_key_rotation     = true
  deletion_window_in_days = 7

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "wsc2026-function-kms-policy"
    Statement = [
      {
        Sid    = "AllowKeyManagement"
        Effect = "Allow"
        Principal = {
          AWS = data.aws_caller_identity.current.arn
        }
        Action = [
          "kms:Create*", "kms:Describe*", "kms:Enable*", "kms:List*",
          "kms:Put*", "kms:Update*", "kms:Revoke*", "kms:Disable*",
          "kms:Get*", "kms:Delete*", "kms:TagResource", "kms:UntagResource",
          "kms:ScheduleKeyDeletion", "kms:CancelKeyDeletion",
          "kms:GenerateDataKey", "kms:Encrypt", "kms:Decrypt"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowLambdaRole"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${local.account_id}:role/wsc2026-book-function-role"
        }
        Action = [
          "kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowLambdaService"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = [
          "kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*",
          "kms:GenerateDataKey*", "kms:DescribeKey", "kms:CreateGrant"
        ]
        Resource = "*"
      }
    ]
  })

  tags = { Name = "wsc2026-function-kms" }
}

resource "aws_kms_alias" "function" {
  name          = "alias/wsc2026-function-kms"
  target_key_id = aws_kms_key.function.key_id
}

# ============================================================
# Outputs
# ============================================================
output "kms_key_arns" {
  value = {
    db       = aws_kms_key.db.arn
    ecr      = aws_kms_key.ecr.arn
    eks      = aws_kms_key.eks.arn
    bucket   = aws_kms_key.bucket.arn
    function = aws_kms_key.function.arn
  }
}
