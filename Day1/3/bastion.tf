########################
# Bastion IAM
########################

resource "aws_iam_role" "bastion" {
  name = "wsc2026-bastion-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "bastion" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "wsc2026-bastion-profile"
  role = aws_iam_role.bastion.name
}

########################
# Staging S3
########################

resource "aws_s3_bucket" "staging" {
  bucket_prefix = "wsc2026-staging-"
  force_destroy = true
}

resource "aws_s3_object" "app_files" {
  for_each = fileset("${path.module}/application", "**")
  bucket   = aws_s3_bucket.staging.id
  key      = "application/${each.value}"
  source   = "${path.module}/application/${each.value}"
  etag     = filemd5("${path.module}/application/${each.value}")
}

resource "aws_s3_object" "k8s_files" {
  for_each = fileset("${path.module}/k8s", "**")
  bucket   = aws_s3_bucket.staging.id
  key      = "k8s/${each.value}"
  source   = "${path.module}/k8s/${each.value}"
  etag     = filemd5("${path.module}/k8s/${each.value}")
}

resource "aws_s3_object" "run_sh" {
  bucket = aws_s3_bucket.staging.id
  key    = "run.sh"
  source = "${path.module}/run.sh"
  etag   = filemd5("${path.module}/run.sh")
}

########################
# Bastion EC2
########################

resource "aws_security_group" "bastion" {
  name        = "wsc2026-bastion-sg"
  vpc_id      = aws_vpc.vpc.id
  description = "Bastion SG"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "wsc2026-bastion-sg" }
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.1-x86_64"]
  }
}

resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.medium"
  subnet_id                   = aws_subnet.hub_a.id
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  iam_instance_profile        = aws_iam_instance_profile.bastion.name
  associate_public_ip_address = true

  user_data = <<-EOF
#!/bin/bash
set -e
yum install -y docker git jq
systemctl enable docker && systemctl start docker
usermod -aG docker ec2-user

curl -LO "https://dl.k8s.io/release/v1.32.0/bin/linux/amd64/kubectl"
chmod +x kubectl && mv kubectl /usr/local/bin/

curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

curl -sL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" | tar xz -C /usr/local/bin

aws s3 cp s3://${aws_s3_bucket.staging.id}/application/ /home/ec2-user/application/ --recursive --region ap-northeast-2
aws s3 cp s3://${aws_s3_bucket.staging.id}/k8s/ /home/ec2-user/k8s/ --recursive --region ap-northeast-2
aws s3 cp s3://${aws_s3_bucket.staging.id}/run.sh /home/ec2-user/run.sh --region ap-northeast-2
chown -R ec2-user:ec2-user /home/ec2-user/application /home/ec2-user/k8s /home/ec2-user/run.sh
find /home/ec2-user -name "*.sh" -exec sed -i 's/\r$//' {} +
chmod +x /home/ec2-user/run.sh

# 자동 실행 (백그라운드 - user_data 완료를 차단하지 않음)
nohup /home/ec2-user/run.sh >> /var/log/run.log 2>&1 &
EOF

  tags = { Name = "wsc2026-bastion" }

  depends_on = [aws_s3_object.app_files, aws_s3_object.k8s_files, aws_s3_object.run_sh]
}

resource "aws_eip" "bastion" {
  instance = aws_instance.bastion.id
  domain   = "vpc"
  tags     = { Name = "wsc2026-bastion-eip" }
}


