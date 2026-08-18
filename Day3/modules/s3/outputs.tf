output "bucket_name" {
  value = aws_s3_bucket.images.bucket
}

output "bucket_arn" {
  value = aws_s3_bucket.images.arn
}

output "bucket_id" {
  value = aws_s3_bucket.images.id
}

output "product_app_role_arn" {
  value = aws_iam_role.product_app.arn
}
