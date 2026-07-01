variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

# NAT egress for private subnets. Set false to skip NAT egress.
variable "enable_nat" {
  type    = bool
  default = true
}

locals {
  azs           = [for s in ["a", "b", "c"] : "${var.region}${s}"]
  public_cidrs  = ["10.0.0.0/24", "10.0.1.0/24", "10.0.2.0/24"]
  private_cidrs = ["10.0.10.0/24", "10.0.11.0/24", "10.0.12.0/24"]
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "mountos" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "mountos-igw" }
}

resource "aws_subnet" "public" {
  count                   = length(local.public_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.public_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true
  tags                    = { Name = "mountos-public-${local.azs[count.index]}", Tier = "public" }
}

resource "aws_subnet" "private" {
  count             = length(local.private_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.private_cidrs[count.index]
  availability_zone = local.azs[count.index]
  tags              = { Name = "mountos-private-${local.azs[count.index]}", Tier = "private" }
}

# Routes modeled as standalone aws_route resources (not inline route {}
# blocks) throughout this module: region-network.tf adds further routes to
# this same table in dedicated mode, and the AWS provider warns that mixing
# inline route blocks with standalone aws_route on one table causes Terraform
# to fight over ownership (each write can silently overwrite/churn the
# other's routes).
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "mountos-public" }
}

resource "aws_route" "public_igw" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Per-AZ NAT: one EIP + gateway per public subnet so a single AZ failure
# does not sever egress for the whole fleet.
resource "aws_eip" "nat" {
  count  = var.enable_nat ? length(aws_subnet.public) : 0
  domain = "vpc"
  tags   = { Name = "mountos-nat-${local.azs[count.index]}" }
}

resource "aws_nat_gateway" "nat" {
  count         = var.enable_nat ? length(aws_subnet.public) : 0
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = { Name = "mountos-nat-${local.azs[count.index]}" }
}

# One private route table per AZ, each routing egress to its own AZ's NAT.
resource "aws_route_table" "private" {
  count  = length(aws_subnet.private)
  vpc_id = aws_vpc.main.id
  tags   = { Name = "mountos-private-${local.azs[count.index]}" }
}

resource "aws_route" "private_nat" {
  count                  = var.enable_nat ? length(aws_subnet.private) : 0
  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat[count.index].id
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}
