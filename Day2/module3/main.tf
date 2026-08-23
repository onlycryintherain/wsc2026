terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-1"
}

variable "contestant_number" {
  description = "선수 비번호를 입력하세요"
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.contestant_number))
    error_message = "비번호는 숫자만 입력해야 합니다."
  }
}

data "aws_caller_identity" "current" {}
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

locals {
  name = "wsc2026-msk"
  az_a = "ap-northeast-1a"
  az_d = "ap-northeast-1d"
}

# VPC and networking
resource "aws_vpc" "msk_vpc" {
  cidr_block           = "192.168.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "msk-vpc" }
}

resource "aws_internet_gateway" "msk_igw" {
  vpc_id = aws_vpc.msk_vpc.id
  tags   = { Name = "msk-igw" }
}

resource "aws_subnet" "msk_pub_a" {
  vpc_id                  = aws_vpc.msk_vpc.id
  cidr_block              = "192.168.0.0/24"
  availability_zone       = local.az_a
  map_public_ip_on_launch = true
  tags                    = { Name = "msk-pub-a" }
}

resource "aws_subnet" "msk_pub_d" {
  vpc_id                  = aws_vpc.msk_vpc.id
  cidr_block              = "192.168.1.0/24"
  availability_zone       = local.az_d
  map_public_ip_on_launch = true
  tags                    = { Name = "msk-pub-d" }
}

resource "aws_subnet" "msk_priv_a" {
  vpc_id            = aws_vpc.msk_vpc.id
  cidr_block        = "192.168.10.0/24"
  availability_zone = local.az_a
  tags              = { Name = "msk-priv-a" }
}

resource "aws_subnet" "msk_priv_d" {
  vpc_id            = aws_vpc.msk_vpc.id
  cidr_block        = "192.168.11.0/24"
  availability_zone = local.az_d
  tags              = { Name = "msk-priv-d" }
}

resource "aws_route_table" "msk_public" {
  vpc_id = aws_vpc.msk_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.msk_igw.id
  }

  tags = { Name = "msk-pub-rtb" }
}

resource "aws_route_table_association" "msk_pub_a" {
  subnet_id      = aws_subnet.msk_pub_a.id
  route_table_id = aws_route_table.msk_public.id
}

resource "aws_route_table_association" "msk_pub_d" {
  subnet_id      = aws_subnet.msk_pub_d.id
  route_table_id = aws_route_table.msk_public.id
}

resource "aws_eip" "msk_nat" {
  domain = "vpc"
  tags   = { Name = "msk-ngw-eip" }
}

resource "aws_nat_gateway" "msk_nat" {
  allocation_id = aws_eip.msk_nat.id
  subnet_id     = aws_subnet.msk_pub_a.id
  depends_on    = [aws_internet_gateway.msk_igw]
  tags          = { Name = "msk-ngw" }
}

resource "aws_route_table" "msk_private_a" {
  vpc_id = aws_vpc.msk_vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.msk_nat.id
  }

  tags = { Name = "msk-priv-a-rtb" }
}

resource "aws_route_table" "msk_private_d" {
  vpc_id = aws_vpc.msk_vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.msk_nat.id
  }

  tags = { Name = "msk-priv-d-rtb" }
}

resource "aws_route_table_association" "msk_priv_a" {
  subnet_id      = aws_subnet.msk_priv_a.id
  route_table_id = aws_route_table.msk_private_a.id
}

resource "aws_route_table_association" "msk_priv_d" {
  subnet_id      = aws_subnet.msk_priv_d.id
  route_table_id = aws_route_table.msk_private_d.id
}

# Producer security group. MSK security-group rules can be added after the MSK SG exists.
resource "aws_security_group" "lambda" {
  name        = "wsc2026-msk-lambda-sg"
  description = "Lambda consumers for private MSK"
  vpc_id      = aws_vpc.msk_vpc.id

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "wsc2026-msk-lambda-sg" }
}

resource "aws_security_group" "producer" {
  name        = "wsc2026-msk-producer-sg"
  description = "Private producer EC2 security group"
  vpc_id      = aws_vpc.msk_vpc.id

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "wsc2026-msk-producer-sg" }
}

# MSK Cluster security group
resource "aws_security_group" "msk" {
  name        = "wsc2026-msk-sg"
  description = "Security group for MSK cluster"
  vpc_id      = aws_vpc.msk_vpc.id

  ingress {
    description     = "Allow traffic from producer"
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    security_groups = [aws_security_group.producer.id]
  }

  ingress {
    description     = "Allow traffic from lambda"
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    security_groups = [aws_security_group.lambda.id]
  }

  ingress {
    description = "Allow traffic from self"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "wsc2026-msk-sg" }
}

# Provisioned MSK cluster with IAM-only client authentication
resource "aws_msk_cluster" "sensor" {
  cluster_name           = "wsc2026-msk-cluster"
  kafka_version          = "3.6.0"
  number_of_broker_nodes = 2

  broker_node_group_info {
    instance_type   = "kafka.t3.small"
    client_subnets  = [aws_subnet.msk_priv_a.id, aws_subnet.msk_priv_d.id]
    security_groups = [aws_security_group.msk.id]

    storage_info {
      ebs_storage_info { volume_size = 100 }
    }
  }

  client_authentication {
    sasl { iam = true }
    unauthenticated = false
  }

  encryption_info {
    encryption_in_transit {
      client_broker = "TLS"
      in_cluster    = true
    }
  }

  tags = { Name = "wsc2026-msk-cluster" }
}

# EC2 IAM role
resource "aws_iam_role" "msk_ec2_role" {
  name = "wsc2026-msk-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.msk_ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "admin" {
  role       = aws_iam_role.msk_ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_role_policy" "msk_producer" {
  name = "wsc2026-msk-producer-policy"
  role = aws_iam_role.msk_ec2_role.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "MskClusterDiscovery"
        Effect   = "Allow"
        Action   = ["kafka:ListClustersV2", "kafka:GetBootstrapBrokers"]
        Resource = "*"
      },
      {
        Sid    = "MskIamProducerAccess"
        Effect = "Allow"
        Action = [
          "kafka-cluster:Connect",
          "kafka-cluster:DescribeCluster",
          "kafka-cluster:CreateTopic",
          "kafka-cluster:DescribeTopic",
          "kafka-cluster:AlterTopic",
          "kafka-cluster:WriteData"
        ]
        Resource = "arn:aws:kafka:ap-northeast-1:${data.aws_caller_identity.current.account_id}:*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "msk_ec2_profile" {
  name = "wsc2026-msk-ec2-role"
  role = aws_iam_role.msk_ec2_role.name
}

# Lambda IAM role for MSK consumers
resource "aws_iam_role" "msk_lambda_role" {
  name = "wsc2026-msk-lambda-role"

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
  role       = aws_iam_role.msk_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_msk" {
  role       = aws_iam_role.msk_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaMSKExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.msk_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_dynamodb" {
  role       = aws_iam_role.msk_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess"
}

resource "aws_iam_role_policy_attachment" "lambda_s3" {
  role       = aws_iam_role.msk_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

resource "aws_iam_role_policy_attachment" "lambda_sns" {
  role       = aws_iam_role.msk_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSNSFullAccess"
}

resource "aws_iam_role_policy" "lambda_msk_data_plane" {
  name = "wsc2026-msk-lambda-data-plane"
  role = aws_iam_role.msk_lambda_role.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "kafka-cluster:*",
        "kafka:*"
      ]
      Resource = "*"
    }]
  })
}

# S3 Bucket and Object for Go binary
resource "aws_s3_bucket" "app_bucket" {
  bucket        = "wsc2026-app-bucket-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_object" "app_binary" {
  bucket = aws_s3_bucket.app_bucket.id
  key    = "app"
  source = "${path.module}/app"
}

resource "aws_iam_role_policy" "s3_access" {
  name = "wsc2026-msk-s3-policy"
  role = aws_iam_role.msk_ec2_role.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:GetObject", "s3:ListBucket"]
      Resource = [
        aws_s3_bucket.app_bucket.arn,
        "${aws_s3_bucket.app_bucket.arn}/*"
      ]
    }]
  })
}

# Producer EC2. The Go binary is deployed separately because it is too large for EC2 user-data.
resource "aws_instance" "sensor_producer" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.msk_priv_a.id
  vpc_security_group_ids = [aws_security_group.producer.id]
  iam_instance_profile   = aws_iam_instance_profile.msk_ec2_profile.name

  user_data = <<-USERDATA
    #!/bin/bash
    set -e
    dnf install -y awscli
    mkdir -p /opt/wsc2026-sensor-producer
    until aws s3 cp s3://${aws_s3_bucket.app_bucket.bucket}/app /opt/wsc2026-sensor-producer/app; do sleep 10; done
    chown -R ec2-user:ec2-user /opt/wsc2026-sensor-producer
    chmod 0755 /opt/wsc2026-sensor-producer/app

    cat > /etc/wsc2026-sensor-producer.env <<'ENV'
    AWS_REGION=ap-northeast-1
    BOOTSTRAP_SERVERS=${aws_msk_cluster.sensor.bootstrap_brokers_sasl_iam}
    TOPIC_RAW=wsc2026-sensor-raw
    ENV
    chmod 0600 /etc/wsc2026-sensor-producer.env

    cat > /etc/systemd/system/wsc2026-sensor-producer.service <<'SERVICE'
    [Unit]
    Description=WSC2026 MSK Sensor Producer
    Wants=network-online.target
    After=network-online.target

    [Service]
    Type=simple
    User=ec2-user
    Group=ec2-user
    WorkingDirectory=/opt/wsc2026-sensor-producer
    EnvironmentFile=/etc/wsc2026-sensor-producer.env
    ExecStart=/opt/wsc2026-sensor-producer/app
    Restart=always
    RestartSec=10

    [Install]
    WantedBy=multi-user.target
    SERVICE

    systemctl daemon-reload
    systemctl enable --now wsc2026-sensor-producer.service
  USERDATA

  depends_on = [
    aws_s3_object.app_binary,
    aws_iam_role_policy.s3_access,
    aws_msk_cluster.sensor
  ]

  tags = { Name = "wsc2026-sensor-producer" }
}

# Processing destinations
resource "aws_dynamodb_table" "sensor_data" {
  name         = "wsc2026-sensor-data"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "sensorId"
  range_key    = "timestamp"

  attribute {
    name = "sensorId"
    type = "S"
  }

  attribute {
    name = "timestamp"
    type = "S"
  }
}

resource "aws_s3_bucket" "sensor_alert" {
  bucket        = "wsc2026-sensor-alert-bucket-${var.contestant_number}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "sensor_alert" {
  bucket                  = aws_s3_bucket.sensor_alert.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lambda consumers
resource "aws_lambda_function" "sensor_consumer" {
  function_name    = "wsc2026-sensor-consumer"
  role             = aws_iam_role.msk_lambda_role.arn
  runtime          = "python3.14"
  handler          = "wsc2026.consumer_handler"
  filename         = "${path.module}/lambda/sensor-consumer.zip"
  source_code_hash = filebase64sha256("${path.module}/lambda/sensor-consumer.zip")
  timeout          = 60
  memory_size      = 256

  environment {
    variables = {
      BOOTSTRAP_SERVERS = aws_msk_cluster.sensor.bootstrap_brokers_sasl_iam
    }
  }

  vpc_config {
    subnet_ids         = [aws_subnet.msk_priv_a.id, aws_subnet.msk_priv_d.id]
    security_group_ids = [aws_security_group.lambda.id]
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic,
    aws_iam_role_policy_attachment.lambda_msk,
    aws_iam_role_policy_attachment.lambda_vpc,
    aws_iam_role_policy_attachment.lambda_dynamodb,
    aws_iam_role_policy_attachment.lambda_sns,
    aws_iam_role_policy.lambda_msk_data_plane
  ]
}

resource "aws_lambda_function" "sensor_alert_consumer" {
  function_name    = "wsc2026-sensor-alert-consumer"
  role             = aws_iam_role.msk_lambda_role.arn
  runtime          = "python3.14"
  handler          = "wsc2026.consumer_handler"
  filename         = "${path.module}/lambda/sensor-alert-consumer.zip"
  source_code_hash = filebase64sha256("${path.module}/lambda/sensor-alert-consumer.zip")
  timeout          = 30
  memory_size      = 128

  environment {
    variables = { S3_BUCKET = aws_s3_bucket.sensor_alert.id }
  }

  vpc_config {
    subnet_ids         = [aws_subnet.msk_priv_a.id, aws_subnet.msk_priv_d.id]
    security_group_ids = [aws_security_group.lambda.id]
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic,
    aws_iam_role_policy_attachment.lambda_msk,
    aws_iam_role_policy_attachment.lambda_vpc,
    aws_iam_role_policy_attachment.lambda_s3,
    aws_iam_role_policy_attachment.lambda_sns,
    aws_iam_role_policy.lambda_msk_data_plane
  ]
}

resource "aws_lambda_event_source_mapping" "sensor_raw" {
  event_source_arn  = aws_msk_cluster.sensor.arn
  function_name     = aws_lambda_function.sensor_consumer.arn
  topics            = ["wsc2026-sensor-raw"]
  starting_position = "LATEST"
  batch_size        = 100
  enabled           = true

  depends_on = [aws_instance.sensor_producer]
}

resource "aws_lambda_event_source_mapping" "sensor_alert" {
  event_source_arn  = aws_msk_cluster.sensor.arn
  function_name     = aws_lambda_function.sensor_alert_consumer.arn
  topics            = ["wsc2026-sensor-alert"]
  starting_position = "LATEST"
  batch_size        = 100
  enabled           = true

  depends_on = [aws_instance.sensor_producer]
}

output "vpc_id" { value = aws_vpc.msk_vpc.id }
output "private_subnet_ids" { value = [aws_subnet.msk_priv_a.id, aws_subnet.msk_priv_d.id] }
output "producer_instance_id" { value = aws_instance.sensor_producer.id }
output "producer_role_arn" { value = aws_iam_role.msk_ec2_role.arn }
output "producer_security_group_id" { value = aws_security_group.producer.id }
output "lambda_role_arn" { value = aws_iam_role.msk_lambda_role.arn }
output "cluster_arn" { value = aws_msk_cluster.sensor.arn }
output "bootstrap_brokers_sasl_iam" { value = aws_msk_cluster.sensor.bootstrap_brokers_sasl_iam }
output "sensor_alert_bucket" { value = aws_s3_bucket.sensor_alert.id }
