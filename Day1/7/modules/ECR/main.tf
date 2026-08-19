resource "aws_ecr_repository" "concert_app" {
  name = var.repository_name

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = var.kms_key_arn
  }

  image_scanning_configuration {
    scan_on_push = var.scan_on_push
  }

  tags = {
    Name = var.repository_name
  }

  lifecycle {
    ignore_changes = [image_tag_mutability]
  }
}
