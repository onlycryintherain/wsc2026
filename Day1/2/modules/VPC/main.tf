resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = var.vpc_name }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "book-igw" }
}

resource "aws_subnet" "public" {
  count                   = length(var.public_subnets_cidr)
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnets_cidr[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true
  tags                    = { Name = var.public_subnet_names[count.index] }
}

resource "aws_subnet" "isolated" {
  count             = length(var.isolated_subnets_cidr)
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.isolated_subnets_cidr[count.index]
  availability_zone = var.availability_zones[count.index]
  tags              = { Name = var.isolated_subnet_names[count.index] }
}

resource "aws_eip" "nat" {
  count  = length(aws_subnet.public)
  domain = "vpc"
  tags   = { Name = "wskorea26-nat-eip-${count.index}" }
}

resource "aws_nat_gateway" "this" {
  count         = length(aws_subnet.public)
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = { Name = count.index == 0 ? "book-ngw-c" : "book-ngw-d" }
  depends_on    = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "wskorea26-public-rtb" }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "isolated" {
  count  = length(var.isolated_subnets_cidr)
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[count.index].id
  }

  tags = { Name = count.index == 0 ? "wskorea26-private-rtb-c" : "wskorea26-private-rtb-d" }
}

resource "aws_route_table_association" "isolated" {
  count          = length(aws_subnet.isolated)
  subnet_id      = aws_subnet.isolated[count.index].id
  route_table_id = aws_route_table.isolated[count.index].id
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.ap-northeast-2.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.isolated[*].id
  tags              = { Name = "wskorea26-vpce-s3" }
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.ap-northeast-2.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.isolated[*].id
  tags              = { Name = "wskorea26-vpce-dynamodb" }
}
