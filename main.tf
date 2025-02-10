# module "network_gateway" {
#   source               = "./modules/network_gateway"
#   network_gateway       = var.network_gateway
# }

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

output "vpc_name" {
    value = aws_vpc.main 
}

# Create Internet Gateways
resource "aws_internet_gateway" "main" {
#   for_each = local.vpc_id_map
  
  vpc_id = aws_vpc.main["10.0.0.0/16"].id

  tags = {
    Name        = "${var.network_gateway.environment}-hw-internet-gateway"
    Environment = var.network_gateway.environment
  }
}

# Create Elastic IPs for NAT Gateways
resource "aws_eip" "nat" {
#   for_each = local.vpc_id_map
  domain   = "vpc"

  tags = {
    Name = "${var.network_gateway.environment}-hw-nat-eip"
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

output "subnets" {
  value  =aws_subnet.public
}

locals {
  vpc_id_map = { for _, v in aws_vpc.main : v.id => v } # Map VPC ID as key
}
# Create Default Route Table for Public Subnets
resource "aws_default_route_table" "default" {
  for_each = local.vpc_id_map # Use VPC ID as the key

  default_route_table_id = each.value.default_route_table_id

  tags = {
    Name        = "${var.network_gateway.environment}-hw-public-route-table-${each.key}"
    Environment = var.network_gateway.environment
  }
  depends_on = [ aws_vpc.main ]
}


output "default_route" {
  value = aws_default_route_table.default
}

# Route for Public Subnets to the Internet Gateway
resource "aws_route" "public_route" {
  for_each = aws_default_route_table.default

  route_table_id         = each.value.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

output "aws_route" {
  value = aws_route.public_route
}
# Associate Public Subnets with Default Route Table
resource "aws_route_table_association" "public_subnet_association" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_default_route_table.default[each.value.vpc_id].id
}

output "aws_route_table_ass" {
  value = aws_route_table_association.public_subnet_association
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
output "subnet-private" {
  value = aws_subnet.private
}
# Create Private Route Table for Each VPC
resource "aws_route_table" "private" {
  for_each = local.vpc_id_map

  vpc_id = each.value.id

  tags = {
    Name = "${var.network_gateway.environment}-hw-private-route-table-${each.key}"
  }
}

output "aws_route_table_private" {
  value = aws_route_table.private
}

# Create NAT Gateway
# resource "aws_nat_gateway" "main" {
#   for_each = local.vpc_id_map 

#   subnet_id     = element([for s in aws_subnet.public : s.id if s.vpc_id == each.value.id], 0)
#   allocation_id = aws_eip.nat[each.key].id

#   tags = {
#     Name = "${var.network_gateway.environment}-hw-nat-gateway-${each.key}"
#   }

#   depends_on = [aws_eip.nat]
# }

resource "aws_nat_gateway" "main" {
  subnet_id     = aws_subnet.public["10.0.1.0/24"].id  # Choose one public subnet
  allocation_id = aws_eip.nat.id

  tags = {
    Name = "${var.network_gateway.environment}-shared-nat"
  }

  depends_on = [aws_eip.nat]
}


# Route for Private Subnets to NAT Gateway
resource "aws_route" "nat_access" {
  for_each = aws_route_table.private

  route_table_id         = each.value.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
}
output "aws-route" {
  value =aws_route.nat_access
}
#Associate Private Subnets with Private Route Table
resource "aws_route_table_association" "private_subnet_association" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.value.vpc_id].id
}
output "aws-route-table_association_private" {
  value= aws_route_table_association.private_subnet_association
}



# resource "aws_ec2_transit_gateway" "this" {
#   description = "HWTransitGateway"
#   tags = {
#     Name        = "${var.network_gateway.environment}-hw-transit-gateway"
#     Environment = var.network_gateway.environment
#   }
# }


# resource "aws_ec2_transit_gateway_vpc_attachment" "tgw_attachments" {
#   for_each = aws_vpc.main  # Iterate over each VPC

#   transit_gateway_id = aws_ec2_transit_gateway.this.id
#   vpc_id             = each.value.id
#   subnet_ids         = [for subnet in aws_subnet.private : subnet.id if subnet.vpc_id == each.value.id] 

#   tags = {
#     Name        = "${var.network_gateway.environment}-hw-transit-gateway-attachment-${each.key}"
#     Environment = var.network_gateway.environment
#   }
# }
