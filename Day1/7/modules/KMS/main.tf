# App Key
resource "aws_kms_key" "app" {
  description             = "App key for Secrets Manager and DynamoDB"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  rotation_period_in_days = var.rotation_period

  tags = {
    Name = replace(var.app_key_alias, "alias/", "")
  }
}

resource "aws_kms_alias" "app" {
  name          = var.app_key_alias
  target_key_id = aws_kms_key.app.key_id
}

# Data Key
resource "aws_kms_key" "data" {
  description             = "Data key for S3 and ECR"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  rotation_period_in_days = var.rotation_period

  tags = {
    Name = replace(var.data_key_alias, "alias/", "")
  }
}

resource "aws_kms_alias" "data" {
  name          = var.data_key_alias
  target_key_id = aws_kms_key.data.key_id
}

# Platform Key (Multi-region primary)
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_kms_key" "platform" {
  description             = "Platform key for EKS, EBS, and Logs (Multi-region)"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  rotation_period_in_days = var.rotation_period
  multi_region            = true

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
        Sid       = "AllowCloudWatchLogs"
        Effect    = "Allow"
        Principal = { Service = "logs.${data.aws_region.current.name}.amazonaws.com" }
        Action    = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource  = "*"
      }
    ]
  })

  tags = {
    Name = replace(var.platform_key_alias, "alias/", "")
  }
}

resource "aws_kms_alias" "platform" {
  name          = var.platform_key_alias
  target_key_id = aws_kms_key.platform.key_id
}
