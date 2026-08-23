terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }
}

provider "aws" {
  region = "eu-west-1"
}

data "aws_caller_identity" "current" {}

# VPC Configuration
resource "aws_vpc" "event_vpc" {
  cidr_block           = "172.16.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "event-vpc"
  }
}

resource "aws_internet_gateway" "event_igw" {
  vpc_id = aws_vpc.event_vpc.id

  tags = {
    Name = "event-igw"
  }
}

resource "aws_subnet" "event_pub_a" {
  vpc_id                  = aws_vpc.event_vpc.id
  cidr_block              = "172.16.0.0/24"
  availability_zone       = "eu-west-1a"
  map_public_ip_on_launch = true

  tags = {
    Name = "event-pub-a"
  }
}

resource "aws_subnet" "event_pub_b" {
  vpc_id                  = aws_vpc.event_vpc.id
  cidr_block              = "172.16.1.0/24"
  availability_zone       = "eu-west-1b"
  map_public_ip_on_launch = true

  tags = {
    Name = "event-pub-b"
  }
}

resource "aws_route_table" "event_pub_rtb" {
  vpc_id = aws_vpc.event_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.event_igw.id
  }

  tags = {
    Name = "event-pub-rtb"
  }
}

resource "aws_route_table_association" "event_pub_a_assoc" {
  subnet_id      = aws_subnet.event_pub_a.id
  route_table_id = aws_route_table.event_pub_rtb.id
}

resource "aws_route_table_association" "event_pub_b_assoc" {
  subnet_id      = aws_subnet.event_pub_b.id
  route_table_id = aws_route_table.event_pub_rtb.id
}

# IAM Role Configuration (EC2)
data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "wsc2026_event_ec2_role" {
  name               = "wsc2026-event-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.wsc2026_event_ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "wsc2026_event_ec2_profile" {
  name = "wsc2026-event-ec2-role"
  role = aws_iam_role.wsc2026_event_ec2_role.name
}

# Role used only by the remediation test.
resource "aws_iam_role" "admin_access_role" {
  name = "AdminAccessRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "admin_access" {
  role       = aws_iam_role.admin_access_role.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# IAM Role Configuration (Lambda)
data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "wsc2026_event_lambda_role" {
  name               = "wsc2026-event-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.wsc2026_event_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_inline_policy" {
  name = "wsc2026-event-lambda-policy"
  role = aws_iam_role.wsc2026_event_lambda_role.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PublishEventAlerts"
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = "arn:aws:sns:eu-west-1:${data.aws_caller_identity.current.account_id}:wsc2026-event-alert"
      },
      {
        Sid    = "EC2AndSecurityGroupRemediation"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceAttribute",
          "ec2:DescribeIamInstanceProfileAssociations",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:AssociateIamInstanceProfile",
          "ec2:ReplaceIamInstanceProfileAssociation",
          "ec2:StopInstances",
          "ec2:StartInstances",
          "ec2:ModifyInstanceAttribute"
        ]
        Resource = "*"
      },
      {
        Sid      = "PassEC2Role"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/wsc2026-event-ec2-role"
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "ec2.amazonaws.com"
          }
        }
      }
    ]
  })
}

# Security Group Configuration
resource "aws_security_group" "wsc2026_event_sg" {
  name        = "wsc2026-event-sg"
  description = "Security group for event EC2 instance"
  vpc_id      = aws_vpc.event_vpc.id

  ingress {
    description = "Allow HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "wsc2026-event-sg"
  }
}

# EC2 Instance Configuration
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

resource "aws_instance" "wsc2026_event_ec2" {
  ami                     = data.aws_ami.amazon_linux_2023.id
  instance_type           = "t3.micro"
  subnet_id               = aws_subnet.event_pub_a.id
  vpc_security_group_ids  = [aws_security_group.wsc2026_event_sg.id]
  iam_instance_profile    = aws_iam_instance_profile.wsc2026_event_ec2_profile.name
  disable_api_termination = true

  # userdata from the provided file
  user_data_base64 = "IyEvYmluL2Jhc2gKZG5mIHVwZGF0ZQpkbmYgaW5zdGFsbCBodHRwZCAteQpzeXN0ZW1jdGwgZW5hYmxlIC0tbm93IGh0dHBkCmhvc3RuYW1lID4gL3Zhci93d3cvaHRtbC9pbmRleC5odG1s"

  tags = {
    Name = "wsc2026-event-ec2"
  }
}

# SNS alert topic
resource "aws_sns_topic" "event_alert" {
  name = "wsc2026-event-alert"
}

# CloudTrail bucket and trail
resource "aws_s3_bucket" "cloudtrail" {
  bucket        = "wsc2026-event-s3-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  bucket                  = aws_s3_bucket.cloudtrail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "cloudtrail_bucket" {
  statement {
    sid       = "AWSCloudTrailAclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.cloudtrail.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = ["arn:aws:cloudtrail:eu-west-1:${data.aws_caller_identity.current.account_id}:trail/wsc2026-event-trail"]
    }
  }

  statement {
    sid       = "AWSCloudTrailWrite"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = ["arn:aws:cloudtrail:eu-west-1:${data.aws_caller_identity.current.account_id}:trail/wsc2026-event-trail"]
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  policy = data.aws_iam_policy_document.cloudtrail_bucket.json
}

resource "aws_cloudtrail" "event" {
  name                          = "wsc2026-event-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail.id
  include_global_service_events = true
  is_multi_region_trail         = false
  enable_logging                = true
  depends_on                    = [aws_s3_bucket_policy.cloudtrail]
}

# Lambda deployment packages
data "archive_file" "sg" {
  type        = "zip"
  output_path = "${path.module}/lambda/sg.zip"
  source {
    content  = file("${path.module}/lambda/sg.py")
    filename = "event_lambda.py"
  }
}

data "archive_file" "role" {
  type        = "zip"
  output_path = "${path.module}/lambda/role.zip"
  source {
    content  = file("${path.module}/lambda/role.py")
    filename = "event_lambda.py"
  }
}

data "archive_file" "termination" {
  type        = "zip"
  output_path = "${path.module}/lambda/termination.zip"
  source {
    content  = file("${path.module}/lambda/termination.py")
    filename = "event_lambda.py"
  }
}

data "archive_file" "type" {
  type        = "zip"
  output_path = "${path.module}/lambda/type.zip"
  source {
    content  = file("${path.module}/lambda/type.py")
    filename = "event_lambda.py"
  }
}

locals {
  lambda_functions = {
    "wsc2026-sg-remediation" = {
      zip  = data.archive_file.sg.output_path
      hash = data.archive_file.sg.output_base64sha256
      environment = {
        SNS_TOPIC_ARN     = aws_sns_topic.event_alert.arn
        SECURITY_GROUP_ID = aws_security_group.wsc2026_event_sg.id
      }
    }
    "wsc2026-role-remediation" = {
      zip  = data.archive_file.role.output_path
      hash = data.archive_file.role.output_base64sha256
      environment = {
        SNS_TOPIC_ARN         = aws_sns_topic.event_alert.arn
        INSTANCE_ID           = aws_instance.wsc2026_event_ec2.id
        INSTANCE_PROFILE_NAME = aws_iam_instance_profile.wsc2026_event_ec2_profile.name
      }
    }
    "wsc2026-termination-protection-remediation" = {
      zip  = data.archive_file.termination.output_path
      hash = data.archive_file.termination.output_base64sha256
      environment = {
        SNS_TOPIC_ARN = aws_sns_topic.event_alert.arn
        INSTANCE_ID   = aws_instance.wsc2026_event_ec2.id
      }
    }
    "wsc2026-ec2-type-remediation" = {
      zip  = data.archive_file.type.output_path
      hash = data.archive_file.type.output_base64sha256
      environment = {
        SNS_TOPIC_ARN          = aws_sns_topic.event_alert.arn
        INSTANCE_ID            = aws_instance.wsc2026_event_ec2.id
        EXPECTED_INSTANCE_TYPE = "t3.micro"
      }
    }
  }
}

resource "aws_lambda_function" "remediation" {
  for_each         = local.lambda_functions
  function_name    = each.key
  role             = aws_iam_role.wsc2026_event_lambda_role.arn
  runtime          = "python3.14"
  handler          = "event_lambda.handler"
  filename         = each.value.zip
  source_code_hash = each.value.hash
  timeout          = each.key == "wsc2026-ec2-type-remediation" ? 180 : 30

  environment {
    variables = each.value.environment
  }

  depends_on = [aws_iam_role_policy_attachment.lambda_basic_execution]
}

# EventBridge rules
resource "aws_cloudwatch_event_rule" "sg" {
  name = "wsc2026-sg-change-rule"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource       = ["ec2.amazonaws.com"]
      eventName         = ["AuthorizeSecurityGroupIngress"]
      requestParameters = { groupId = [aws_security_group.wsc2026_event_sg.id] }
    }
  })
}

resource "aws_cloudwatch_event_rule" "role" {
  name = "wsc2026-role-change-rule"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["ec2.amazonaws.com"]
      eventName   = ["AssociateIamInstanceProfile", "ReplaceIamInstanceProfileAssociation", "DisassociateIamInstanceProfile"]
    }
  })
}

resource "aws_cloudwatch_event_rule" "termination" {
  name = "wsc2026-termination-protection-change-rule"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["ec2.amazonaws.com"]
      eventName   = ["ModifyInstanceAttribute"]
      requestParameters = {
        instanceId            = [aws_instance.wsc2026_event_ec2.id]
        disableApiTermination = { value = [false] }
      }
    }
  })
}

resource "aws_cloudwatch_event_rule" "type" {
  name = "wsc2026-ec2-type-change-rule"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["ec2.amazonaws.com"]
      eventName   = ["ModifyInstanceAttribute"]
      requestParameters = {
        instanceId   = [aws_instance.wsc2026_event_ec2.id]
        instanceType = { value = [{ anything-but = "t3.micro" }] }
      }
    }
  })
}

locals {
  event_targets = {
    sg = {
      rule     = aws_cloudwatch_event_rule.sg.name
      rule_arn = aws_cloudwatch_event_rule.sg.arn
      function = "wsc2026-sg-remediation"
    }
    role = {
      rule     = aws_cloudwatch_event_rule.role.name
      rule_arn = aws_cloudwatch_event_rule.role.arn
      function = "wsc2026-role-remediation"
    }
    termination = {
      rule     = aws_cloudwatch_event_rule.termination.name
      rule_arn = aws_cloudwatch_event_rule.termination.arn
      function = "wsc2026-termination-protection-remediation"
    }
    type = {
      rule     = aws_cloudwatch_event_rule.type.name
      rule_arn = aws_cloudwatch_event_rule.type.arn
      function = "wsc2026-ec2-type-remediation"
    }
  }
}

resource "aws_cloudwatch_event_target" "lambda" {
  for_each  = local.event_targets
  rule      = each.value.rule
  target_id = "${each.key}-remediation-target"
  arn       = aws_lambda_function.remediation[each.value.function].arn
}

resource "aws_lambda_permission" "eventbridge" {
  for_each      = local.event_targets
  statement_id  = "AllowEventBridge-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.remediation[each.value.function].function_name
  principal     = "events.amazonaws.com"
  source_arn    = each.value.rule_arn
}

output "instance_id" { value = aws_instance.wsc2026_event_ec2.id }
output "security_group_id" { value = aws_security_group.wsc2026_event_sg.id }
output "sns_topic_arn" { value = aws_sns_topic.event_alert.arn }
