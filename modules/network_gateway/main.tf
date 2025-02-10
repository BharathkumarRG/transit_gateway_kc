
data "aws_availability_zones" "available" {
  state = "available" # Fetch only available AZs
}

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

locals {
  vpc_id_map = { for _, v in aws_vpc.main : v.id => v } # Map VPC ID as key
}

resource "aws_default_route_table" "default" {
  for_each = local.vpc_id_map # Use VPC ID as the key

  default_route_table_id = each.value.default_route_table_id

  tags = {
    Name        = "${var.network_gateway.environment}-hw-public-route-table-${each.key}"
    Environment = var.network_gateway.environment
  }
  depends_on = [ aws_vpc.main ]
}

output "default-rt-table" {
  value = aws_default_route_table.default
}


# Public Subnets


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

output "pub-subnet" {
  value = aws_subnet.public
}

resource "aws_internet_gateway" "main" {
#   for_each = local.vpc_id_map
  
  vpc_id = aws_vpc.main["10.0.0.0/16"].id

  tags = {
    Name        = "${var.network_gateway.environment}-hw-internet-gateway"
    Environment = var.network_gateway.environment
  }
}

output "igw" {
  value= aws_internet_gateway.main
}

# resource "aws_route" "public_route" {
#   route_table_id         = aws_default_route_table.default[aws_vpc.main["10.0.0.0/16"].id].id
#   destination_cidr_block = "0.0.0.0/0"
#   gateway_id             = aws_internet_gateway.main.id
# }

output "rt-pub-rt" {
  value = aws_route.public_route
}

# Associate Private Subnets with Private Route Table

resource "aws_route_table_association" "public_subnet_association" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_default_route_table.default[each.value.vpc_id].id
}

output "value" {
  value = aws_route_table_association.public_subnet_association
}

resource "aws_eip" "nat" {
#   for_each = local.vpc_id_map
  domain   = "vpc"

  tags = {
    Name = "${var.network_gateway.environment}-hw-nat-eip"
  }
}

output "elastic-ip" {
  value = aws_eip.nat
}
resource "aws_nat_gateway" "main" {
  subnet_id     = aws_subnet.public["10.0.1.0/24"].id  # Choose one public subnet
  allocation_id = aws_eip.nat.id

  tags = {
    Name = "${var.network_gateway.environment}-shared-nat"
  }

  depends_on = [aws_eip.nat]
}

output "nat-gateway" {
  value =aws_nat_gateway.main
}


# AWS subnet private 

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

# Private Route Table


resource "aws_route_table" "private" {
  for_each = local.vpc_id_map

  vpc_id = each.value.id

  tags = {
    Name = "${var.network_gateway.environment}-hw-private-route-table-${each.key}"
  }
}

# resource "aws_route" "nat_access" {
#   for_each = aws_route_table.private

#   route_table_id         = each.value.id
#   destination_cidr_block = "0.0.0.0/0"
#   nat_gateway_id         = aws_nat_gateway.main.id
#   # depends_on = [ aws_ec2_transit_gateway_vpc_attachment.tgw_attachments ]
# }

# Associate Private Subnets with Private Route Table

resource "aws_route_table_association" "private_subnet_association" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.value.vpc_id].id
}

resource "aws_ec2_transit_gateway" "this" {
  description = "HWTransitGateway"
  tags = {
    Name        = "${var.network_gateway.environment}-hw-transit-gateway"
    Environment = var.network_gateway.environment
  }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "tgw_attachments" {
  for_each = aws_vpc.main  # Iterate over each VPC

  transit_gateway_id = aws_ec2_transit_gateway.this.id
  vpc_id             = each.value.id
  subnet_ids         = [for subnet in aws_subnet.private : subnet.id if subnet.vpc_id == each.value.id] 

  tags = {
    Name        = "${var.network_gateway.environment}-hw-transit-gateway-attachment-${each.key}"
    Environment = var.network_gateway.environment
  }
}

# # Transit Gateway Route Table
# resource "aws_ec2_transit_gateway_route_table" "tgw_rt" {
#   transit_gateway_id = aws_ec2_transit_gateway.this.id
#   tags = {
#     Name = "${var.network_gateway.environment}-tgw-rt"
#   }
# }

# # Associate Transit Gateway Route Table with Attachments
# resource "aws_ec2_transit_gateway_route_table_association" "tgw_associations" {
#   for_each = aws_ec2_transit_gateway_vpc_attachment.tgw_attachments

#   transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.tgw_rt.id
#   transit_gateway_attachment_id  = each.value.id
# }

# Route for Internet-bound traffic from other VPCs to Main VPC NAT Gateway
resource "aws_ec2_transit_gateway_route" "internet_route" {
  transit_gateway_route_table_id = aws_ec2_transit_gateway.this.association_default_route_table_id
  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.tgw_attachments["10.0.0.0/16"].id # Attach to Main VPC with NAT
}


# Update Private Route Tables to use Transit Gateway
resource "aws_route" "private_to_tgw" {
  for_each = {
    for k, v in aws_route_table.private : k => v
    if k != aws_vpc.main["10.0.0.0/16"].id # Exclude NAT Gateway VPC
  }

  route_table_id         = each.value.id
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = aws_ec2_transit_gateway.this.id
}

# Allow public subnets in Main VPC to access the Internet via IGW
resource "aws_route" "public_route" {
  route_table_id         = aws_default_route_table.default[aws_vpc.main["10.0.0.0/16"].id].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

# Private Subnets in Main VPC use NAT Gateway
resource "aws_route" "nat_access" {
  route_table_id         = aws_route_table.private[aws_vpc.main["10.0.0.0/16"].id].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
}
