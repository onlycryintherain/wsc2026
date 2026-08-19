resource "aws_cloudfront_origin_access_control" "this" {
  name                              = var.oac_name
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "this" {
  enabled             = true
  comment             = var.distribution_name
  default_root_object = "index.html"
  price_class         = "PriceClass_All"

  origin {
    domain_name              = var.s3_bucket_regional_domain_name
    origin_id                = var.s3_origin_id
    origin_path              = "/web/main"
    origin_access_control_id = aws_cloudfront_origin_access_control.this.id

    custom_header {
      name  = "wskorea26-s3-access"
      value = "true"
    }
  }

  dynamic "origin" {
    for_each = var.api_origin_enabled && var.api_origin_domain_name != "" ? [1] : []

    content {
      domain_name = var.api_origin_domain_name
      origin_id   = var.alb_origin_id

      custom_origin_config {
        http_port              = 80
        https_port             = 443
        origin_protocol_policy = "http-only"
        origin_ssl_protocols   = ["TLSv1.2"]
      }

      custom_header {
        name  = "X-Origin-Verify"
        value = "wskorea26-cf"
      }
    }
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = var.s3_origin_id
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }
  }

  dynamic "ordered_cache_behavior" {
    for_each = var.api_origin_enabled && var.api_origin_domain_name != "" ? [1] : []

    content {
      path_pattern           = "/book*"
      allowed_methods        = ["GET", "HEAD", "OPTIONS", "POST", "PUT", "PATCH", "DELETE"]
      cached_methods         = ["GET", "HEAD"]
      target_origin_id       = var.alb_origin_id
      viewer_protocol_policy = "redirect-to-https"

      forwarded_values {
        query_string = true
        headers      = ["*"]
        cookies { forward = "all" }
      }

      min_ttl     = 0
      default_ttl = 0
      max_ttl     = 0
    }
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = { Name = var.distribution_name }
}

resource "aws_s3_bucket_policy" "cloudfront" {
  bucket = var.s3_bucket_id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontOAC"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${var.s3_bucket_arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.this.arn
        }
      }
    }]
  })
}
