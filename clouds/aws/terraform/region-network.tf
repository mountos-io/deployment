# Region VPC placement. shared (default): region resources live in the hub's
# VPC (aws_vpc.main) — the original single-VPC design, unchanged. dedicated:
# the region gets its own VPC in the SAME AWS account and SAME AWS region as
# the hub (var.region), connected by an intra-account VPC peering connection.
# The hub<->region SRPC traffic that would otherwise rely on same-VPC security
# group references switches to CIDR-based rules (see security-groups.tf).
#
# NOT covered here: true cross-account regions (needs a second `aws` provider
# alias + explicit peering accepter/RAM share + cross-account IAM trust) and
# true cross-AWS-region regions (needs a second provider alias with a
# different region). Both are separate, larger changes.
variable "region_vpc_mode" {
  type        = string
  description = "Region VPC placement: shared (default; region resources live in the hub VPC) | dedicated (region gets its own VPC, peered to the hub VPC via intra-account VPC peering)."
  default     = "shared"
  validation {
    condition     = contains(["shared", "dedicated"], var.region_vpc_mode)
    error_message = "region_vpc_mode must be shared or dedicated."
  }
}

variable "region_vpc_cidr" {
  type        = string
  description = "CIDR for the region's dedicated VPC. Used only when region_vpc_mode = dedicated. Must not overlap the hub VPC CIDR (var.vpc_cidr)."
  default     = "10.1.0.0/16"
}

locals {
  region_dedicated_vpc = var.region_vpc_mode == "dedicated"
  region_public_cidrs  = ["10.1.0.0/24", "10.1.1.0/24", "10.1.2.0/24"]
  region_private_cidrs = ["10.1.10.0/24", "10.1.11.0/24", "10.1.12.0/24"]

  # Region-scoped resources (SGs, RDS) attach to these instead of
  # aws_vpc.main / aws_subnet.private so they land in the right VPC in either
  # mode. Backend-only (region RDS) stays on the PRIVATE ones.
  region_vpc_id  = local.region_dedicated_vpc ? aws_vpc.region[0].id : aws_vpc.main.id
  region_subnets = local.region_dedicated_vpc ? aws_subnet.region_private : aws_subnet.private

  # Client-facing data-plane services (dataserv, blockserv, hdfsserv,
  # s3gatewayserv) advertise a public IPv4 and are reached directly by IP —
  # they need PUBLIC subnets (IGW route), unlike region RDS/Vault.
  region_public_subnets = local.region_dedicated_vpc ? aws_subnet.region_public : aws_subnet.public
}

resource "aws_vpc" "region" {
  count                = local.region_dedicated_vpc ? 1 : 0
  cidr_block           = var.region_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "mountos-region" }
}

resource "aws_internet_gateway" "region_igw" {
  count  = local.region_dedicated_vpc ? 1 : 0
  vpc_id = aws_vpc.region[0].id
  tags   = { Name = "mountos-region-igw" }
}

resource "aws_subnet" "region_public" {
  count                   = local.region_dedicated_vpc ? length(local.region_public_cidrs) : 0
  vpc_id                  = aws_vpc.region[0].id
  cidr_block              = local.region_public_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true
  tags                    = { Name = "mountos-region-public-${local.azs[count.index]}", Tier = "public" }
}

resource "aws_subnet" "region_private" {
  count             = local.region_dedicated_vpc ? length(local.region_private_cidrs) : 0
  vpc_id            = aws_vpc.region[0].id
  cidr_block        = local.region_private_cidrs[count.index]
  availability_zone = local.azs[count.index]
  tags              = { Name = "mountos-region-private-${local.azs[count.index]}", Tier = "private" }
}

# Routes modeled as standalone aws_route resources (not inline route {}
# blocks), matching network.tf — avoids the provider-documented risk of a
# route table's inline block and an external aws_route fighting for ownership.
resource "aws_route_table" "region_public" {
  count  = local.region_dedicated_vpc ? 1 : 0
  vpc_id = aws_vpc.region[0].id
  tags   = { Name = "mountos-region-public" }
}

resource "aws_route" "region_public_igw" {
  count                  = local.region_dedicated_vpc ? 1 : 0
  route_table_id         = aws_route_table.region_public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.region_igw[0].id
}

# dataserv/blockserv/hdfsserv/s3gatewayserv run in THIS subnet tier (public IP
# requirement) — they still need a route back to the hub VPC (the NLB for SRPC).
resource "aws_route" "region_public_to_hub" {
  count                     = local.region_dedicated_vpc ? 1 : 0
  route_table_id            = aws_route_table.region_public[0].id
  destination_cidr_block    = var.vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.region[0].id
}

resource "aws_route_table_association" "region_public" {
  count          = local.region_dedicated_vpc ? length(aws_subnet.region_public) : 0
  subnet_id      = aws_subnet.region_public[count.index].id
  route_table_id = aws_route_table.region_public[0].id
}

# Per-AZ NAT, same pattern as the hub (network.tf).
resource "aws_eip" "region_nat" {
  count  = local.region_dedicated_vpc && var.enable_nat ? length(aws_subnet.region_public) : 0
  domain = "vpc"
  tags   = { Name = "mountos-region-nat-${local.azs[count.index]}" }
}

resource "aws_nat_gateway" "region_nat" {
  count         = local.region_dedicated_vpc && var.enable_nat ? length(aws_subnet.region_public) : 0
  allocation_id = aws_eip.region_nat[count.index].id
  subnet_id     = aws_subnet.region_public[count.index].id
  tags          = { Name = "mountos-region-nat-${local.azs[count.index]}" }
}

# One private route table per AZ: NAT egress (if enabled) plus a route back to
# the hub VPC over the peering connection. Only region RDS lives here now
# (dataserv/blockserv/hdfsserv/s3gatewayserv sit in region_public for their
# public-IP requirement) — the hub route is currently unused but harmless to
# keep for any future private-subnet resource that needs it.
resource "aws_route_table" "region_private" {
  count  = local.region_dedicated_vpc ? length(aws_subnet.region_private) : 0
  vpc_id = aws_vpc.region[0].id
  tags   = { Name = "mountos-region-private-${local.azs[count.index]}" }
}

resource "aws_route" "region_private_nat" {
  count                  = local.region_dedicated_vpc && var.enable_nat ? length(aws_subnet.region_private) : 0
  route_table_id         = aws_route_table.region_private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.region_nat[count.index].id
}

resource "aws_route" "region_private_to_hub" {
  count                     = local.region_dedicated_vpc ? length(aws_subnet.region_private) : 0
  route_table_id            = aws_route_table.region_private[count.index].id
  destination_cidr_block    = var.vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.region[0].id
}

resource "aws_route_table_association" "region_private" {
  count          = local.region_dedicated_vpc ? length(aws_subnet.region_private) : 0
  subnet_id      = aws_subnet.region_private[count.index].id
  route_table_id = aws_route_table.region_private[count.index].id
}

# Intra-account peering: same AWS account and AWS region as the hub, so
# auto_accept resolves the handshake without a separate accepter resource.
resource "aws_vpc_peering_connection" "region" {
  count       = local.region_dedicated_vpc ? 1 : 0
  vpc_id      = aws_vpc.main.id
  peer_vpc_id = aws_vpc.region[0].id
  auto_accept = true
  tags        = { Name = "mountos-hub-region-peering" }
}

# Peered VPCs don't resolve each other's private DNS by default. Without this,
# dataserv/gcserv/blockserv/gateway can't resolve the hub NLB's DNS name
# (aws_lb.appserv_srpc.dns_name, an internal NLB) to a private IP.
resource "aws_vpc_peering_connection_options" "region" {
  count                     = local.region_dedicated_vpc ? 1 : 0
  vpc_peering_connection_id = aws_vpc_peering_connection.region[0].id

  accepter {
    allow_remote_vpc_dns_resolution = true
  }
  requester {
    allow_remote_vpc_dns_resolution = true
  }
}

# Hub-side routes back to the region VPC, one per hub private route table (one
# per AZ), so the hub appserv fleet can reach dataserv/gcserv/blockserv/gateway.
resource "aws_route" "hub_to_region" {
  count                     = local.region_dedicated_vpc ? length(aws_route_table.private) : 0
  route_table_id            = aws_route_table.private[count.index].id
  destination_cidr_block    = var.region_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.region[0].id
}

# The appserv_srpc NLB (lb.tf) sits in the hub's PUBLIC subnets (internal, but
# still placed there for the ALB/NAT tier), governed by aws_route_table.public
# — which only has the IGW default route. Without this, the NLB has no route
# back to the region VPC and SRPC registration/heartbeat TCP connections from a
# dedicated-mode region would blackhole on the return path.
resource "aws_route" "hub_public_to_region" {
  count                     = local.region_dedicated_vpc ? 1 : 0
  route_table_id            = aws_route_table.public.id
  destination_cidr_block    = var.region_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.region[0].id
}

output "region_vpc_id" {
  value = local.region_dedicated_vpc ? aws_vpc.region[0].id : null
}

output "region_public_subnet_ids" {
  value = local.region_dedicated_vpc ? aws_subnet.region_public[*].id : null
}

output "region_private_subnet_ids" {
  value = local.region_dedicated_vpc ? aws_subnet.region_private[*].id : null
}
