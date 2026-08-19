resource "aws_dynamodb_table" "concert" {
  name           = var.table_name
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = var.hash_key

  attribute {
    name = var.hash_key
    type = "S"
  }

  attribute {
    name = var.gsi_hash_key
    type = "S"
  }

  attribute {
    name = var.gsi_range_key
    type = "S"
  }

  global_secondary_index {
    name            = var.gsi_name
    hash_key        = var.gsi_hash_key
    range_key       = var.gsi_range_key
    projection_type = var.gsi_projection
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_key_arn
  }

  point_in_time_recovery {
    enabled = true
  }

  deletion_protection_enabled = true

  tags = {
    Name = var.table_name
  }
}
