resource "aws_ecr_repository" "this" {
  name                 = var.repository_name
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  encryption_configuration {
    encryption_type = "KMS"
  }

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = { Name = var.repository_name }
}
