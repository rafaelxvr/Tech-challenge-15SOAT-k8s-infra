variable "name" { type = string }
variable "aws_region" { type = string }
variable "vpc_cidr" { type = string }
variable "availability_zones" {
  type = list(string)
  validation {
    condition     = length(var.availability_zones) == 2 && length(distinct(var.availability_zones)) == 2
    error_message = "The reviewed topology requires exactly two distinct availability zones."
  }
}

variable "public_subnet_cidrs" {
  type = list(string)
  validation {
    condition     = length(var.public_subnet_cidrs) == 2
    error_message = "Provide one public subnet CIDR for each approved availability zone."
  }
}

variable "private_subnet_cidrs" {
  type = list(string)
  validation {
    condition     = length(var.private_subnet_cidrs) == 2
    error_message = "Provide one private workload/CodeBuild subnet CIDR for each approved availability zone."
  }
}

variable "database_subnet_cidrs" {
  type = list(string)
  validation {
    condition     = length(var.database_subnet_cidrs) == 2
    error_message = "Provide one isolated database subnet CIDR for each approved availability zone."
  }
}
