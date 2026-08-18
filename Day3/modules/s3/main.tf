resource "aws_s3_bucket" "images" {
  bucket_prefix = "apdev-product-images-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "images" {
  bucket                  = aws_s3_bucket.images.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "binary_user" {
  bucket = aws_s3_bucket.images.id
  key    = "binary/user"
  source = "${var.source_path}/application/binary/user"
}

resource "aws_s3_object" "binary_product" {
  bucket = aws_s3_bucket.images.id
  key    = "binary/product"
  source = "${var.source_path}/application/binary/product"
}

resource "aws_s3_object" "binary_stress" {
  bucket = aws_s3_bucket.images.id
  key    = "binary/stress"
  source = "${var.source_path}/application/binary/stress"
}

resource "aws_s3_object" "dump" {
  bucket = aws_s3_bucket.images.id
  key    = "load_user.dump"
  source = "${var.source_path}/application/load_user.dump"
}

resource "aws_s3_object" "bastion_script" {
  bucket = aws_s3_bucket.images.id
  key    = "scripts/bastion_setup.sh"
  content = templatefile("${var.source_path}/scripts/bastion_setup.sh", {
    region             = var.region
    cluster            = var.cluster_name
    account_id         = var.account_id
    s3_bucket          = aws_s3_bucket.images.bucket
    vpc_id             = var.vpc_id
    karpenter_arn      = var.karpenter_role_arn
    karpenter_queue    = var.karpenter_queue_name
    node_role          = var.node_role_name
    product_app_arn    = aws_iam_role.product_app.arn
    cluster_name       = var.cluster_name
    log_bucket         = var.log_bucket
    db_identifier      = var.db_identifier
    db_name            = var.db_name
    db_username        = var.db_username
    db_secret_name     = var.db_secret_name
    db_proxy_name      = var.db_proxy_name
    node_instance_type = var.node_instance_type
  })
}

# IAM for product app (IRSA)
resource "aws_iam_role" "product_app" {
  name               = "${var.cluster_name}-product-app"
  assume_role_policy = data.aws_iam_policy_document.product_app_assume.json
}

data "aws_iam_policy_document" "product_app_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_url}:sub"
      values   = ["system:serviceaccount:app:product"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "product_app_s3" {
  name = "${var.cluster_name}-product-app-s3"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
      Resource = "${aws_s3_bucket.images.arn}/*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "product_app_s3" {
  role       = aws_iam_role.product_app.name
  policy_arn = aws_iam_policy.product_app_s3.arn
}
