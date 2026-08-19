# Replica key in us-east-1 (for WAF logs)
resource "aws_kms_replica_key" "platform_replica" {
  provider                = aws.us_east_1
  description             = "Replica of Platform key in us-east-1"
  deletion_window_in_days = 7
  primary_key_arn         = aws_kms_key.platform.arn
}

resource "aws_kms_alias" "platform_replica" {
  provider      = aws.us_east_1
  name          = "alias/unicorn-kms-platform"
  target_key_id = aws_kms_replica_key.platform_replica.key_id
}
