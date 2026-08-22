resource "aws_iam_role" "lambda" {
  name = "wsc2026-book-function-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_policy" "lambda_dynamodb" {
  name = "wsc2026-book-function-policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:Query"]
        Resource = ["${aws_dynamodb_table.book.arn}", "${aws_dynamodb_table.book.arn}/index/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:DescribeKey"]
        Resource = [aws_kms_key.db.arn, aws_kms_key.function.arn]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_dynamodb" {
  role       = aws_iam_role.lambda.name
  policy_arn = aws_iam_policy.lambda_dynamodb.arn
}

# Encrypt TABLE_NAME env var
resource "aws_kms_ciphertext" "table_name" {
  key_id    = aws_kms_key.function.key_id
  plaintext = aws_dynamodb_table.book.name
  context = {
    LambdaFunctionName = "wsc2026-book-get-function"
  }
}

data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/lambda_function.py"
  output_path = "${path.module}/lambda_function.zip"
}

resource "aws_lambda_function" "book_get" {
  function_name    = "wsc2026-book-get-function"
  runtime          = "python3.12"
  handler          = "lambda_function.lambda_handler"
  role             = aws_iam_role.lambda.arn
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  kms_key_arn      = aws_kms_key.function.arn

  environment {
    variables = {
      TABLE_NAME = aws_kms_ciphertext.table_name.ciphertext_blob
    }
  }

  tags = { Name = "wsc2026-book-get-function" }
}

resource "aws_lambda_function_url" "book_get" {
  function_name      = aws_lambda_function.book_get.function_name
  authorization_type = "NONE"
}
