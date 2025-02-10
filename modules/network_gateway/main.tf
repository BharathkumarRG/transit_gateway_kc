provider "aws" {
  region  = var.network_gateway.aws_region
  profile = var.network_gateway.aws_provider
}

data "aws_availability_zones" "available" {
  state = "available"
}

# Create VPCs
resource "aws_vpc" "main" {
  for_each = toset(var.network_gateway.aws_vpc_cidr)

  cidr_block           = each.value
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name        = "${var.network_gateway.environment}-hw-vpc-${each.value}"
    Environment = var.network_gateway.environment
  }
}

# Create Internet Gateways
resource "aws_internet_gateway" "main" {
  for_each = aws_vpc.main
  
  vpc_id = each.value.id

  tags = {
    Name        = "${var.network_gateway.environment}-hw-internet-gateway-${each.key}"
    Environment = var.network_gateway.environment
  }
}

# Create Elastic IPs for NAT Gateways
resource "aws_eip" "nat" {
  for_each = aws_vpc.main
  domain   = "vpc"

  tags = {
    Name = "${var.network_gateway.environment}-hw-nat-eip-${each.key}"
  }
}

locals {
  flattened_public_subnets = flatten([
    for vpc_index, subnets in var.network_gateway.public_subnet_cidrs : [
      for subnet in subnets : {
        vpc_index  = vpc_index
        cidr_block = subnet
      }
    ]
  ])
}


# Create Public Subnets
resource "aws_subnet" "public" {
  for_each = { for idx, subnet in local.flattened_public_subnets : subnet.cidr_block => subnet }

  vpc_id                  = aws_vpc.main[var.network_gateway.aws_vpc_cidr[each.value.vpc_index]].id
  cidr_block              = each.key
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[lookup(var.network_gateway.subnet_to_az_map, each.key)]

  tags = {
    Name        = "${var.network_gateway.environment}-hw-public-subnet-${each.key}"
    Environment = var.network_gateway.environment
  }
}

# Create Default Route Table for Public Subnets
resource "aws_default_route_table" "default" {
  for_each = aws_vpc.main

  default_route_table_id = each.value.default_route_table_id

  tags = {
    Name        = "${var.network_gateway.environment}-hw-public-route-table-${each.key}"
    Environment = var.network_gateway.environment
  }
}

# Route for Public Subnets to the Internet Gateway
resource "aws_route" "public_route" {
  for_each = aws_default_route_table.default

  route_table_id         = each.value.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main[each.key].id
}

# Associate Public Subnets with Default Route Table
resource "aws_route_table_association" "public_subnet_association" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_default_route_table.default[each.key].id
}


locals {
  flattened_private_subnets = flatten([
    for vpc_index, subnets in var.network_gateway.private_subnet_cidrs : [
      for subnet in subnets : {
        vpc_index  = vpc_index
        cidr_block = subnet
      }
    ]
  ])
}

# Create Private Subnets
resource "aws_subnet" "private" {
  for_each = { for idx, subnet in local.flattened_private_subnets : subnet.cidr_block => subnet }

  vpc_id            = aws_vpc.main[var.network_gateway.aws_vpc_cidr[each.value.vpc_index]].id
  cidr_block        = each.key
  map_public_ip_on_launch = false
  availability_zone = data.aws_availability_zones.available.names[lookup(var.network_gateway.subnet_to_az_map, each.key)]

  tags = {
    Name        = "${var.network_gateway.environment}-hw-private-subnet-${each.key}"
    Environment = var.network_gateway.environment
  }
}

# Create Private Route Table for Each VPC
resource "aws_route_table" "private" {
  for_each = aws_vpc.main

  vpc_id = each.value.id

  tags = {
    Name = "${var.network_gateway.environment}-hw-private-route-table-${each.key}"
  }
}

# Create NAT Gateway
resource "aws_nat_gateway" "main" {
  for_each = aws_vpc.main  

  subnet_id     = element([for s in aws_subnet.public : s.id if s.vpc_id == each.value.id], 0)
  allocation_id = aws_eip.nat[each.key].id

  tags = {
    Name = "${var.network_gateway.environment}-hw-nat-gateway-${each.key}"
  }

  depends_on = [aws_eip.nat]
}

# Route for Private Subnets to NAT Gateway
resource "aws_route" "nat_access" {
  for_each = aws_route_table.private

  route_table_id         = each.value.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main[each.key].id
}

# Associate Private Subnets with Private Route Table
resource "aws_route_table_association" "private_subnet_association" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}
