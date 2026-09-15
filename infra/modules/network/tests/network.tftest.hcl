mock_provider "aws" {}

variables {
  name                  = "oficina-phase3"
  aws_region            = "us-east-1"
  vpc_cidr              = "10.42.0.0/16"
  availability_zones    = ["us-east-1a", "us-east-1b"]
  public_subnet_cidrs   = ["10.42.0.0/24", "10.42.1.0/24"]
  private_subnet_cidrs  = ["10.42.16.0/20", "10.42.32.0/20"]
  database_subnet_cidrs = ["10.42.64.0/24", "10.42.65.0/24"]
}

run "one_nat_and_private_topology" {
  command = apply

  assert {
    condition     = aws_eip.nat.domain == "vpc"
    error_message = "The free-tier reviewed topology permits exactly one NAT gateway and one EIP."
  }
  assert {
    condition     = length(aws_subnet.private) == 2 && alltrue([for subnet in aws_subnet.private : subnet.map_public_ip_on_launch == false])
    error_message = "Workers and CodeBuild need two private subnets without public addresses."
  }
  assert {
    condition     = length(aws_subnet.database) == 2 && alltrue([for subnet in aws_subnet.database : subnet.map_public_ip_on_launch == false])
    error_message = "Database subnets must be isolated and private."
  }
  assert {
    condition     = aws_vpc_endpoint.s3.vpc_endpoint_type == "Gateway" && aws_vpc_endpoint.dynamodb.vpc_endpoint_type == "Gateway"
    error_message = "Only S3 and DynamoDB gateway endpoints are approved in foundation."
  }
}
