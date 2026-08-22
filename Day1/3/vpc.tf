provider "aws" {
  region = "ap-northeast-2"
}

########################
# VPC
########################
resource "aws_vpc" "vpc" {
  cidr_block           = "192.168.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "wsc2026-skills-vpc"
  }
}

########################
# Internet Gateway
########################
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id

  tags = {
    Name = "wsc2026-skills-igw"
  }
}

########################
# Subnets
########################

# HUB (Public)
resource "aws_subnet" "hub_a" {
  vpc_id            = aws_vpc.vpc.id
  cidr_block        = "192.168.1.0/24"
  availability_zone = "ap-northeast-2a"

  tags = {
    Name = "wsc2026-skills-hub-sub-a"
  }
}

resource "aws_subnet" "hub_b" {
  vpc_id            = aws_vpc.vpc.id
  cidr_block        = "192.168.10.0/24"
  availability_zone = "ap-northeast-2b"

  tags = {
    Name = "wsc2026-skills-hub-sub-b"
  }
}

# APP (Private)
resource "aws_subnet" "app_a" {
  vpc_id            = aws_vpc.vpc.id
  cidr_block        = "192.168.2.0/24"
  availability_zone = "ap-northeast-2a"

  tags = {
    Name = "wsc2026-skills-app-sub-a"
  }
}

resource "aws_subnet" "app_b" {
  vpc_id            = aws_vpc.vpc.id
  cidr_block        = "192.168.20.0/24"
  availability_zone = "ap-northeast-2b"

  tags = {
    Name = "wsc2026-skills-app-sub-b"
  }
}

########################
# Elastic IP (for NAT)
########################
resource "aws_eip" "nat_a" {
  domain = "vpc"
}

resource "aws_eip" "nat_b" {
  domain = "vpc"
}

########################
# NAT Gateway
########################
resource "aws_nat_gateway" "nat_a" {
  allocation_id = aws_eip.nat_a.id
  subnet_id     = aws_subnet.hub_a.id

  tags = {
    Name = "wsc2026-skills-nat-a"
  }

  depends_on = [aws_internet_gateway.igw]
}

resource "aws_nat_gateway" "nat_b" {
  allocation_id = aws_eip.nat_b.id
  subnet_id     = aws_subnet.hub_b.id

  tags = {
    Name = "wsc2026-skills-nat-b"
  }

  depends_on = [aws_internet_gateway.igw]
}

########################
# Route Tables
########################

# HUB (Public)
resource "aws_route_table" "hub" {
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "wsc2026-skills-hub-rtb"
  }
}

# APP A
resource "aws_route_table" "app_a" {
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_a.id
  }

  tags = {
    Name = "wsc2026-skills-app-rtb-a"
  }
}

# APP B
resource "aws_route_table" "app_b" {
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_b.id
  }

  tags = {
    Name = "wsc2026-skills-app-rtb-b"
  }
}

########################
# Route Table Association
########################

# HUB
resource "aws_route_table_association" "hub_a" {
  subnet_id      = aws_subnet.hub_a.id
  route_table_id = aws_route_table.hub.id
}

resource "aws_route_table_association" "hub_b" {
  subnet_id      = aws_subnet.hub_b.id
  route_table_id = aws_route_table.hub.id
}

# APP
resource "aws_route_table_association" "app_a" {
  subnet_id      = aws_subnet.app_a.id
  route_table_id = aws_route_table.app_a.id
}

resource "aws_route_table_association" "app_b" {
  subnet_id      = aws_subnet.app_b.id
  route_table_id = aws_route_table.app_b.id
}

########################
# VPC Endpoints
########################
resource "aws_security_group" "vpce" {
  name        = "wsc2026-vpce-sg"
  description = "VPC Endpoint SG"
  vpc_id      = aws_vpc.vpc.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["192.168.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "wsc2026-vpce-sg" }
}
