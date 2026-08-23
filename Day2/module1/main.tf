terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
  }
}

provider "aws" {
  region = "ap-southeast-1"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

variable "student_num" {
  description = "비번호"
}



# S3 Bucket
resource "aws_s3_bucket" "main" {
  bucket        = "wsc2026-student-score-bucket-${var.student_num}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "main" {
  bucket = aws_s3_bucket.main.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# S3 folders
resource "aws_s3_object" "input" {
  bucket  = aws_s3_bucket.main.id
  key     = "input/"
  content = ""
}

# Wait for IAM propagation before uploading
resource "time_sleep" "wait_for_iam" {
  depends_on = [
    aws_iam_role_policy.lambda_score,
    aws_iam_role_policy.sfn,
    aws_s3_bucket_notification.main,
    aws_lambda_function.trigger,
    aws_lambda_function.score,
    aws_sfn_state_machine.main
  ]
  create_duration = "30s"
}

# Upload test.csv to input/
resource "aws_s3_object" "test_csv" {
  bucket = aws_s3_bucket.main.id
  key    = "input/test.csv"
  source = "${path.module}/test.csv"
  etag   = filemd5("${path.module}/test.csv")

  depends_on = [time_sleep.wait_for_iam]
}

# DynamoDB Table
resource "aws_dynamodb_table" "main" {
  name           = "wsc2026-student-score"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "studentId"
  range_key      = "examDate"

  attribute {
    name = "studentId"
    type = "S"
  }

  attribute {
    name = "examDate"
    type = "S"
  }
}

# IAM Role for Lambda (Score Processing)
resource "aws_iam_role" "lambda_score" {
  name = "wsc2026-lambda-student-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_score" {
  name = "wsc2026-lambda-student-policy"
  role = aws_iam_role.lambda_score.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.main.arn,
          "${aws_s3_bucket.main.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = ["dynamodb:PutItem", "dynamodb:GetItem"]
        Resource = aws_dynamodb_table.main.arn
      },
      {
        Effect = "Allow"
        Action = ["states:StartExecution"]
        Resource = aws_sfn_state_machine.main.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:*"
      }
    ]
  })
}

# Lambda Function - Score Processing
data "archive_file" "lambda_score" {
  type        = "zip"
  source_file = "${path.module}/lambda_score.py"
  output_path = "${path.module}/lambda_score.zip"
}

resource "aws_lambda_function" "score" {
  function_name    = "wsc2026-student-score-function"
  role             = aws_iam_role.lambda_score.arn
  handler          = "lambda_score.handler"
  runtime          = "python3.12"
  timeout          = 60
  filename         = data.archive_file.lambda_score.output_path
  source_code_hash = data.archive_file.lambda_score.output_base64sha256

  environment {
    variables = {
      S3_BUCKET = aws_s3_bucket.main.id
      DDB_TABLE = aws_dynamodb_table.main.name
    }
  }
}

# Lambda Function - Trigger
data "archive_file" "lambda_trigger" {
  type        = "zip"
  source_file = "${path.module}/lambda_trigger.py"
  output_path = "${path.module}/lambda_trigger.zip"
}

resource "aws_lambda_function" "trigger" {
  function_name    = "wsc2026-student-trigger-function"
  role             = aws_iam_role.lambda_score.arn
  handler          = "lambda_trigger.handler"
  runtime          = "python3.12"
  timeout          = 30
  filename         = data.archive_file.lambda_trigger.output_path
  source_code_hash = data.archive_file.lambda_trigger.output_base64sha256

  environment {
    variables = {
      STATE_MACHINE_ARN = aws_sfn_state_machine.main.arn
    }
  }
}

# S3 Event Notification to Lambda
resource "aws_lambda_permission" "s3" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.trigger.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.main.arn
  source_account = data.aws_caller_identity.current.account_id
}

# S3 알림 설정
resource "aws_s3_bucket_notification" "main" {
  bucket = aws_s3_bucket.main.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.trigger.arn
    events             = ["s3:ObjectCreated:*"]
    filter_prefix      = "input/"
    filter_suffix      = ".csv"
  }

  depends_on = [aws_lambda_permission.s3]
}

# IAM Role for Step Functions
resource "aws_iam_role" "sfn" {
  name = "wsc2026-stepfunction-student-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "states.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "sfn" {
  name = "wsc2026-student-score-workflow-policy"
  role = aws_iam_role.sfn.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["lambda:InvokeFunction"]
        Resource = aws_lambda_function.score.arn
      },
      {
        Effect = "Allow"
        Action = ["s3:HeadObject", "s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:CopyObject"]
        Resource = [
          aws_s3_bucket.main.arn,
          "${aws_s3_bucket.main.arn}/*"
        ]
      }
    ]
  })
}

# Step Functions State Machine
resource "aws_sfn_state_machine" "main" {
  name     = "wsc2026-student-score-workflow"
  role_arn = aws_iam_role.sfn.arn
  type     = "STANDARD"

  definition = <<EOF
{
  "Comment": "Student Score Processing Workflow",
  "StartAt": "ProcessStudentData",
  "States": {
    "ProcessStudentData": {
      "Type": "Task",
      "Resource": "arn:aws:states:::lambda:invoke",
      "Parameters": {
        "FunctionName": "${aws_lambda_function.score.function_name}",
        "Payload.$": "$"
      },
      "Retry": [{
        "ErrorEquals": ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException"],
        "IntervalSeconds": 2,
        "MaxAttempts": 3
      }],
      "End": true
    }
  }
}
EOF
}



output "s3_bucket" {
  value = aws_s3_bucket.main.id
}

output "dynamodb_table" {
  value = aws_dynamodb_table.main.name
}

output "state_machine_arn" {
  value = aws_sfn_state_machine.main.arn
}
