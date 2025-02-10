variable "network_gateway" {
  type = object({
    aws_provider         = string
    aws_region           = string
    environment          = string
    aws_account_id       = string
    aws_vpc_cidr         = list(string)
    public_subnet_cidrs  = list(list(string))
    private_subnet_cidrs = list(list(string))
    subnet_to_az_map     = map(number)
  })
}
