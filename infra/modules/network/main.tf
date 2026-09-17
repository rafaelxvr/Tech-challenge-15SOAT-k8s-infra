locals {
  azs = { for index, az in var.availability_zones : az => index }
  tags = {
    "project"                           = "oficina-phase3"
    "kubernetes.io/cluster/${var.name}" = "shared"
  }
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = merge(local.tags, { Name = "${var.name}-vpc" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name}-igw" })
}

resource "aws_subnet" "public" {
  for_each                = local.azs
  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = var.public_subnet_cidrs[each.value]
  map_public_ip_on_launch = false
  tags                    = merge(local.tags, { Name = "${var.name}-public-${each.value + 1}", "kubernetes.io/role/elb" = "1" })
}

resource "aws_subnet" "private" {
  for_each                = local.azs
  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = var.private_subnet_cidrs[each.value]
  map_public_ip_on_launch = false
  tags                    = merge(local.tags, { Name = "${var.name}-private-${each.value + 1}", "kubernetes.io/role/internal-elb" = "1" })
}

resource "aws_subnet" "database" {
  for_each                = local.azs
  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = var.database_subnet_cidrs[each.value]
  map_public_ip_on_launch = false
  tags                    = merge(local.tags, { Name = "${var.name}-database-${each.value + 1}" })
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = merge(local.tags, { Name = "${var.name}-nat" })
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[var.availability_zones[0]].id
  depends_on    = [aws_internet_gateway.this]
  tags          = merge(local.tags, { Name = "${var.name}-nat" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = merge(local.tags, { Name = "${var.name}-public" })
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }
  tags = merge(local.tags, { Name = "${var.name}-private" })
}

resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table" "database" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name}-database-isolated" })
}

resource "aws_route_table_association" "database" {
  for_each       = aws_subnet.database
  subnet_id      = each.value.id
  route_table_id = aws_route_table.database.id
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.aws_region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
}
