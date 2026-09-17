output "vpc_id" { value = aws_vpc.this.id }
output "vpc_cidr" { value = aws_vpc.this.cidr_block }
output "private_subnet_ids" { value = [for az in var.availability_zones : aws_subnet.private[az].id] }
output "database_subnet_ids" { value = [for az in var.availability_zones : aws_subnet.database[az].id] }
output "public_subnet_ids" { value = [for az in var.availability_zones : aws_subnet.public[az].id] }
output "availability_zones" { value = var.availability_zones }
output "private_route_table_id" { value = aws_route_table.private.id }
