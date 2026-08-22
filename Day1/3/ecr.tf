resource "aws_ecr_repository" "book" {
  name                 = "wsc2026-book-ecr"
  image_tag_mutability = "MUTABLE_WITH_EXCLUSION"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  image_tag_mutability_exclusion_filter {
    filter      = "v1*"
    filter_type = "WILDCARD"
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.ecr.arn
  }

  tags = { Name = "wsc2026-book-ecr" }
}
