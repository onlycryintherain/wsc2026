resource "aws_dynamodb_table" "book" {
  name                        = "wsc2026-book-table"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "client_id"
  deletion_protection_enabled = true

  attribute {
    name = "client_id"
    type = "S"
  }

  attribute {
    name = "booking_id"
    type = "S"
  }

  global_secondary_index {
    name            = "wsc2026-booking-gsi"
    hash_key        = "booking_id"
    projection_type = "ALL"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.db.arn
  }

  point_in_time_recovery {
    enabled                 = true
    recovery_period_in_days = 35
  }

  tags = { Name = "wsc2026-book-table" }
}

resource "aws_dynamodb_resource_policy" "book" {
  resource_arn = aws_dynamodb_table.book.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowEKSPodAccess"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.pod_identity.arn }
        Action    = "dynamodb:PutItem"
        Resource  = aws_dynamodb_table.book.arn
      },
      {
        Sid       = "AllowLambdaQuery"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.lambda.arn }
        Action    = "dynamodb:Query"
        Resource  = "${aws_dynamodb_table.book.arn}/index/*"
      }
    ]
  })
}
