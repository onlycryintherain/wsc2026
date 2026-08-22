resource "aws_s3_bucket" "static" {
  bucket = "wsc2026-static-${random_string.suffix.result}-${var.bi_number}-bucket"
  tags   = { Name = "wsc2026-static" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "static" {
  bucket = aws_s3_bucket.static.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.bucket.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "static" {
  bucket                  = aws_s3_bucket.static.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "static_dir" {
  bucket                 = aws_s3_bucket.static.id
  key                    = "static/"
  content                = ""
  content_type           = "application/x-directory"
  server_side_encryption = "aws:kms"
  kms_key_id             = aws_kms_key.bucket.arn
  bucket_key_enabled     = true
}

resource "aws_s3_object" "index_html" {
  bucket                 = aws_s3_bucket.static.id
  key                    = "static/index.html"
  content                = "<html><body><h1>wsc2026</h1></body></html>"
  content_type           = "text/html"
  server_side_encryption = "aws:kms"
  kms_key_id             = aws_kms_key.bucket.arn
  bucket_key_enabled     = true
}

resource "aws_s3_object" "main_jpeg" {
  bucket                 = aws_s3_bucket.static.id
  key                    = "static/main.jpeg"
  content                = "placeholder"
  content_type           = "image/jpeg"
  server_side_encryption = "aws:kms"
  kms_key_id             = aws_kms_key.bucket.arn
  bucket_key_enabled     = true
}

resource "aws_s3_bucket_policy" "static" {
  bucket = aws_s3_bucket.static.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontOAC"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.static.arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.cdn.arn
        }
      }
    }]
  })
}
