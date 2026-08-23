terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    awscc = {
      source  = "hashicorp/awscc"
      version = "~> 1.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
  }
}

provider "aws" {
  region = "ap-northeast-2"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

# VPC
resource "aws_vpc" "main" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "analytics-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "analytics-igw" }
}

# Public subnets for the ALB
resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.20.0.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "analytics-pub-a" }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.20.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true
  tags                    = { Name = "analytics-pub-b" }
}

# Private subnets for the application. EC2 is intentionally placed in private-a.
resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.20.100.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]
  tags              = { Name = "analytics-priv-a" }
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.20.101.0/24"
  availability_zone = data.aws_availability_zones.available.names[1]
  tags              = { Name = "analytics-priv-b" }
}

resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_a.id
  tags          = { Name = "analytics-ngw" }
  depends_on    = [aws_internet_gateway.main]
}

# Route tables
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "analytics-pub-rtb" }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private_a" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = { Name = "analytics-priv-a-rtb" }
}

resource "aws_route_table" "private_b" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = { Name = "analytics-priv-b-rtb" }
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private_a.id
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private_b.id
}

# Security group for EC2. Port 5000 is reachable only from the ALB;
# SSM is used for administration, so SSH is not exposed.
resource "aws_security_group" "ec2" {
  name        = "wsc2026-analytics-ec2-sg"
  description = "EC2 security group"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 5000
    to_port         = 5000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "wsc2026-analytics-ec2-sg" }
}

resource "aws_security_group" "alb" {
  name        = "wsc2026-analytics-alb-sg"
  description = "ALB security group"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "wsc2026-analytics-alb-sg" }
}

# EC2 IAM role
resource "aws_iam_role" "ec2" {
  name = "wsc2026-analytics-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "ec2" {
  name = "wsc2026-analytics-ec2-policy"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "kinesis:PutRecord"
      Resource = aws_kinesis_stream.main.arn
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.ec2.name
}

resource "aws_iam_instance_profile" "ec2" {
  name = "wsc2026-analytics-ec2-profile"
  role = aws_iam_role.ec2.name
}

# EC2 instance
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-*-x86_64"]
  }
}

resource "aws_instance" "main" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.private_a.id
  vpc_security_group_ids = [aws_security_group.ec2.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  # aws_instance.user_data expects the shell script, not a pre-encoded value.
  user_data = <<-USERDATA
#!/bin/bash
dnf install -y python3.11 python3.11-pip
ln -sf /usr/bin/python3.11 /usr/bin/python3

mkdir -p /opt/app
cat > /opt/app/app.py << 'APPEOF'
import json
import os
import random
import uuid
from datetime import datetime, timezone

import boto3
from flask import Flask, jsonify

app = Flask(__name__)
STREAM_NAME = os.environ.get("STREAM_NAME")
REGION = os.environ.get("AWS_REGION")
if not STREAM_NAME or not REGION:
    raise RuntimeError("STREAM_NAME and AWS_REGION environment variables are required")
kinesis = boto3.client("kinesis", region_name=REGION)

PRODUCTS = [
    {"name": "Laptop", "price": 1200000},
    {"name": "Mouse", "price": 25000},
    {"name": "Keyboard", "price": 55000},
    {"name": "Monitor", "price": 350000},
    {"name": "Headset", "price": 89000},
]

def generate_order():
    product = random.choice(PRODUCTS)
    return {
        "order_id": str(uuid.uuid4()),
        "product_name": product["name"],
        "price": product["price"],
        "quantity": random.randint(1, 5),
        "event_time": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S"),
    }

@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "healthy"})

@app.route("/order", methods=["POST"])
def create_order():
    order = generate_order()
    kinesis.put_record(
        StreamName=STREAM_NAME,
        Data=json.dumps(order),
        PartitionKey=order["order_id"],
    )
    return jsonify(order), 201

@app.route("/orders/generate", methods=["POST"])
def generate_orders():
    count = 10
    orders = []
    for _ in range(count):
        order = generate_order()
        kinesis.put_record(
            StreamName=STREAM_NAME,
            Data=json.dumps(order),
            PartitionKey=order["order_id"],
        )
        orders.append(order)
    return jsonify({"generated": count, "orders": orders}), 201

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
APPEOF

cat > /opt/app/requirements.txt << 'REQEOF'
flask==3.1.1
boto3==1.35.0
gunicorn==23.0.0
REQEOF
python3.11 -m pip install --no-cache-dir -r /opt/app/requirements.txt

cat > /etc/systemd/system/app.service << 'SVCEOF'
[Unit]
Description=Order Application
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/app
Environment="STREAM_NAME=wsc2026-order-stream"
Environment="AWS_REGION=ap-northeast-2"
ExecStart=/usr/local/bin/gunicorn --bind 0.0.0.0:5000 app:app
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable app
systemctl start app
  USERDATA

  tags = { Name = "wsc2026-analytics-ec2" }
}

# ALB
resource "aws_lb" "main" {
  name               = "wsc2026-analytics-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_b.id]
}

resource "aws_lb_target_group" "main" {
  name     = "wsc2026-analytics-tg"
  port     = 5000
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path = "/health"
    port = "5000"
  }
}

resource "aws_lb_listener" "main" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }
}

resource "aws_lb_target_group_attachment" "main" {
  target_group_arn = aws_lb_target_group.main.arn
  target_id        = aws_instance.main.id
  port             = 5000
}

# Kinesis Data Stream
resource "aws_kinesis_stream" "main" {
  name = "wsc2026-order-stream"

  stream_mode_details {
    stream_mode = "ON_DEMAND"
  }
}

# Glue database and table used by the Flink Studio Notebook
resource "aws_glue_catalog_database" "flink" {
  name = "wsc2026_analytics_flink"
}

resource "aws_glue_catalog_table" "order_stream" {
  name          = "order_stream"
  database_name = aws_glue_catalog_database.flink.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    classification                                    = "json"
    typeOfData                                        = "kinesis"
    format                                            = "json"
    "aws.region"                                      = "ap-northeast-2"
    "managed-flink.proctime"                          = "proctime"
    "managed-flink.rowtime"                           = "event_time"
    "managed-flink.watermark.event_time.milliseconds" = "5000"
  }

  storage_descriptor {
    location      = aws_kinesis_stream.main.arn
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"
    }

    columns {
      name = "event_time"
      type = "timestamp"
    }
    columns {
      name = "order_id"
      type = "string"
    }
    columns {
      name = "price"
      type = "double"
    }
    columns {
      name = "product_name"
      type = "string"
    }
    columns {
      name = "quantity"
      type = "bigint"
    }
  }

  depends_on = [aws_kinesis_stream.main]
}

# Wait for IAM propagation before creating the Flink application
resource "time_sleep" "wait_for_flink_iam" {
  depends_on      = [aws_iam_role_policy.flink]
  create_duration = "15s"
}

# Kinesis Data Analytics (Flink Studio)
resource "awscc_kinesisanalyticsv2_application" "flink" {
  application_name       = "wsc2026-analytics-flink"
  runtime_environment    = "ZEPPELIN-FLINK-3_0"
  application_mode       = "INTERACTIVE"
  service_execution_role = aws_iam_role.flink.arn

  application_configuration = {
    application_snapshot_configuration = {
      snapshots_enabled = false
    }
    flink_application_configuration = {
      parallelism_configuration = {
        configuration_type   = "CUSTOM"
        parallelism          = 1
        parallelism_per_kpu  = 1
        auto_scaling_enabled = false
      }
    }
    zeppelin_application_configuration = {
      catalog_configuration = {
        glue_data_catalog_configuration = {
          database_arn = aws_glue_catalog_database.flink.arn
        }
      }
    }
  }

  depends_on = [
    aws_kinesis_stream.main,
    aws_glue_catalog_table.order_stream,
    aws_iam_role_policy.flink,
    time_sleep.wait_for_flink_iam,
  ]
}

resource "aws_iam_role" "flink" {
  name = "wsc2026-analytics-flink-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "kinesisanalytics.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "flink" {
  name = "wsc2026-analytics-flink-policy"
  role = aws_iam_role.flink.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kinesis:DescribeStream",
          "kinesis:DescribeStreamSummary",
          "kinesis:GetShardIterator",
          "kinesis:GetRecords",
          "kinesis:ListShards"
        ]
        Resource = aws_kinesis_stream.main.arn
      },
      {
        Effect = "Allow"
        Action = [
          "glue:GetDatabase",
          "glue:GetTable",
          "glue:GetTables"
        ]
        Resource = [
          aws_glue_catalog_database.flink.arn,
          "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:table/${aws_glue_catalog_database.flink.name}/order_stream"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "*"
      }
    ]
  })
}

output "alb_dns" {
  value = aws_lb.main.dns_name
}

output "kinesis_stream" {
  value = aws_kinesis_stream.main.name
}

output "ec2_id" {
  value = aws_instance.main.id
}
