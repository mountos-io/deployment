# Per-service security groups, derived from the authoritative port map.
# Three tiers: client-facing (open to client_cidr), intra-cluster (peer SG only), never-exposed
# (pprof 6060-6160 = loopback; HTTP metrics 8080/METRICS_PORT = monitoring only — not opened here).
#
# IMPORTANT: blockserv / s3gatewayserv / hdfsserv otherwise pick a DYNAMIC SRPC port (ephemeral :0),
# which cannot be firewalled. Deploy MUST set PORT_RANGE on those services to exactly the range below
# so appserv -> service SRPC is allowed by the security group.

variable "client_cidr" {
  description = "CIDR allowed to reach client-facing ports (appserv 443, dataserv 6464, blockserv 9100, gateways 8484/9870) (required; the CIDR allowed to reach client-facing + hub ports — do not use 0.0.0.0/0 in production)."
  type        = string
}

locals {
  srpc_range_from = 9500
  srpc_range_to   = 9600 # set PORT_RANGE=9500-9600 on blockserv/s3gatewayserv/hdfsserv
}

# ---------- security group shells (rules attached separately to avoid cross-SG cycles) ----------
resource "aws_security_group" "appserv" {
  name        = "mountos-appserv"
  description = "HUB appserv: public HTTPS + SRPC registration"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "mountos-appserv" }
}

resource "aws_security_group" "dataserv" {
  name        = "mountos-dataserv"
  description = "dataserv: client data + raft + SRPC"
  vpc_id      = local.region_vpc_id
  tags        = { Name = "mountos-dataserv" }
}

resource "aws_security_group" "gcserv" {
  name        = "mountos-gcserv"
  description = "gcserv: SRPC from HUB (standalone only)"
  vpc_id      = local.region_vpc_id
  tags        = { Name = "mountos-gcserv" }
}

resource "aws_security_group" "blockserv" {
  name        = "mountos-blockserv"
  description = "blockserv: client block + peer + SRPC"
  vpc_id      = local.region_vpc_id
  tags        = { Name = "mountos-blockserv" }
}

resource "aws_security_group" "gateway" {
  name        = "mountos-gateway"
  description = "s3gatewayserv/hdfsserv: client S3/WebHDFS + SRPC"
  vpc_id      = local.region_vpc_id
  tags        = { Name = "mountos-gateway" }
}

# ---------- egress: allow all, every group ----------
resource "aws_vpc_security_group_egress_rule" "appserv_all" {
  security_group_id = aws_security_group.appserv.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
resource "aws_vpc_security_group_egress_rule" "dataserv_all" {
  security_group_id = aws_security_group.dataserv.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
resource "aws_vpc_security_group_egress_rule" "gcserv_all" {
  security_group_id = aws_security_group.gcserv.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
resource "aws_vpc_security_group_egress_rule" "blockserv_all" {
  security_group_id = aws_security_group.blockserv.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
resource "aws_vpc_security_group_egress_rule" "gateway_all" {
  security_group_id = aws_security_group.gateway.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------- appserv ingress ----------
# (Clients terminate at the ALB on 443 — see lb.tf. The instances themselves
# listen only on 8443 (from the ALB) and 9443 (SRPC), so no 443 rule here.)
# SRPC 9443 (FIXED): region services register/heartbeat. In HA this sits behind an NLB TCP passthrough.
# shared mode (default): SG-to-SG references, only valid within one VPC.
resource "aws_vpc_security_group_ingress_rule" "appserv_srpc_from_dataserv" {
  count                        = local.region_dedicated_vpc ? 0 : 1
  security_group_id            = aws_security_group.appserv.id
  referenced_security_group_id = aws_security_group.dataserv.id
  from_port                    = 9443
  to_port                      = 9443
  ip_protocol                  = "tcp"
  description                  = "SRPC registration from dataserv"
}
resource "aws_vpc_security_group_ingress_rule" "appserv_srpc_from_gcserv" {
  count                        = local.region_dedicated_vpc ? 0 : 1
  security_group_id            = aws_security_group.appserv.id
  referenced_security_group_id = aws_security_group.gcserv.id
  from_port                    = 9443
  to_port                      = 9443
  ip_protocol                  = "tcp"
  description                  = "SRPC registration from gcserv"
}
resource "aws_vpc_security_group_ingress_rule" "appserv_srpc_from_blockserv" {
  count                        = local.region_dedicated_vpc ? 0 : 1
  security_group_id            = aws_security_group.appserv.id
  referenced_security_group_id = aws_security_group.blockserv.id
  from_port                    = 9443
  to_port                      = 9443
  ip_protocol                  = "tcp"
  description                  = "SRPC registration from blockserv"
}
resource "aws_vpc_security_group_ingress_rule" "appserv_srpc_from_gateway" {
  count                        = local.region_dedicated_vpc ? 0 : 1
  security_group_id            = aws_security_group.appserv.id
  referenced_security_group_id = aws_security_group.gateway.id
  from_port                    = 9443
  to_port                      = 9443
  ip_protocol                  = "tcp"
  description                  = "SRPC registration from gateways"
}
# dedicated mode: one CIDR-based rule covers all four region services (same
# port), since SG references don't work across the peered VPC boundary.
resource "aws_vpc_security_group_ingress_rule" "appserv_srpc_from_region_cidr" {
  count             = local.region_dedicated_vpc ? 1 : 0
  security_group_id = aws_security_group.appserv.id
  cidr_ipv4         = var.region_vpc_cidr
  from_port         = 9443
  to_port           = 9443
  ip_protocol       = "tcp"
  description       = "SRPC registration from the region VPC (dedicated mode)"
}
# NLB health checks reach instance targets from the NLB nodes' OWN private IPs
# (not the client's), so the SG-to-SG rules above never match them — without
# this rule every SRPC target stays permanently unhealthy. SRPC itself is
# Noise/Ed25519-authenticated, so a VPC-wide TCP allow is acceptable here.
resource "aws_vpc_security_group_ingress_rule" "appserv_srpc_healthcheck" {
  security_group_id = aws_security_group.appserv.id
  cidr_ipv4         = var.vpc_cidr
  from_port         = 9443
  to_port           = 9443
  ip_protocol       = "tcp"
  description       = "SRPC health checks from the NLB nodes"
}

# ---------- dataserv ingress ----------
resource "aws_vpc_security_group_ingress_rule" "dataserv_client" {
  security_group_id = aws_security_group.dataserv.id
  cidr_ipv4         = var.client_cidr
  from_port         = 6464
  to_port           = 6464
  ip_protocol       = "tcp"
  description       = "client metadata (mfuse), Noise"
}
resource "aws_vpc_security_group_ingress_rule" "dataserv_data_from_gateway" {
  security_group_id            = aws_security_group.dataserv.id
  referenced_security_group_id = aws_security_group.gateway.id
  from_port                    = 6464
  to_port                      = 6464
  ip_protocol                  = "tcp"
  description                  = "gateways -> dataserv data plane"
}
resource "aws_vpc_security_group_ingress_rule" "dataserv_raft_self" {
  security_group_id            = aws_security_group.dataserv.id
  referenced_security_group_id = aws_security_group.dataserv.id
  from_port                    = 6465
  to_port                      = 6465
  ip_protocol                  = "tcp"
  description                  = "raft peers (quorum), Noise"
}
resource "aws_vpc_security_group_ingress_rule" "dataserv_srpc_from_appserv" {
  count                        = local.region_dedicated_vpc ? 0 : 1
  security_group_id            = aws_security_group.dataserv.id
  referenced_security_group_id = aws_security_group.appserv.id
  from_port                    = 6466
  to_port                      = 6466
  ip_protocol                  = "tcp"
  description                  = "SRPC from HUB (vault refresh, volume ops)"
}
resource "aws_vpc_security_group_ingress_rule" "dataserv_srpc_from_appserv_cidr" {
  count             = local.region_dedicated_vpc ? 1 : 0
  security_group_id = aws_security_group.dataserv.id
  cidr_ipv4         = var.vpc_cidr
  from_port         = 6466
  to_port           = 6466
  ip_protocol       = "tcp"
  description       = "SRPC from HUB VPC (dedicated mode, vault refresh, volume ops)"
}

# ---------- gcserv ingress (standalone; co-located on dataserv needs none) ----------
resource "aws_vpc_security_group_ingress_rule" "gcserv_srpc_from_appserv" {
  count                        = local.region_dedicated_vpc ? 0 : 1
  security_group_id            = aws_security_group.gcserv.id
  referenced_security_group_id = aws_security_group.appserv.id
  from_port                    = 8081
  to_port                      = 8081
  ip_protocol                  = "tcp"
  description                  = "SRPC from HUB"
}
resource "aws_vpc_security_group_ingress_rule" "gcserv_srpc_from_appserv_cidr" {
  count             = local.region_dedicated_vpc ? 1 : 0
  security_group_id = aws_security_group.gcserv.id
  cidr_ipv4         = var.vpc_cidr
  from_port         = 8081
  to_port           = 8081
  ip_protocol       = "tcp"
  description       = "SRPC from HUB VPC (dedicated mode)"
}

# ---------- blockserv ingress ----------
resource "aws_vpc_security_group_ingress_rule" "blockserv_client" {
  security_group_id = aws_security_group.blockserv.id
  cidr_ipv4         = var.client_cidr
  from_port         = 9100
  to_port           = 9100
  ip_protocol       = "tcp"
  description       = "client block I/O, Noise"
}
# Peer 9101: block volumes form a mesh across distinct clusters. Single-cluster template references self;
# add the other clusters' blockserv SGs for the full cross-cluster mesh.
resource "aws_vpc_security_group_ingress_rule" "blockserv_peer_self" {
  security_group_id            = aws_security_group.blockserv.id
  referenced_security_group_id = aws_security_group.blockserv.id
  from_port                    = 9101
  to_port                      = 9101
  ip_protocol                  = "tcp"
  description                  = "blockserv peer replication"
}
resource "aws_vpc_security_group_ingress_rule" "blockserv_srpc_from_appserv" {
  count                        = local.region_dedicated_vpc ? 0 : 1
  security_group_id            = aws_security_group.blockserv.id
  referenced_security_group_id = aws_security_group.appserv.id
  from_port                    = local.srpc_range_from
  to_port                      = local.srpc_range_to
  ip_protocol                  = "tcp"
  description                  = "SRPC from HUB (PORT_RANGE must be pinned to this range)"
}
resource "aws_vpc_security_group_ingress_rule" "blockserv_srpc_from_appserv_cidr" {
  count             = local.region_dedicated_vpc ? 1 : 0
  security_group_id = aws_security_group.blockserv.id
  cidr_ipv4         = var.vpc_cidr
  from_port         = local.srpc_range_from
  to_port           = local.srpc_range_to
  ip_protocol       = "tcp"
  description       = "SRPC from HUB VPC (dedicated mode; PORT_RANGE must be pinned to this range)"
}

# ---------- gateway ingress (s3gatewayserv 8484, hdfsserv 9870) ----------
resource "aws_vpc_security_group_ingress_rule" "gateway_s3" {
  security_group_id = aws_security_group.gateway.id
  cidr_ipv4         = var.client_cidr
  from_port         = 8484
  to_port           = 8484
  ip_protocol       = "tcp"
  description       = "S3 REST (SigV4)"
}
resource "aws_vpc_security_group_ingress_rule" "gateway_hdfs" {
  security_group_id = aws_security_group.gateway.id
  cidr_ipv4         = var.client_cidr
  from_port         = 9870
  to_port           = 9870
  ip_protocol       = "tcp"
  description       = "WebHDFS"
}
resource "aws_vpc_security_group_ingress_rule" "gateway_srpc_from_appserv" {
  count                        = local.region_dedicated_vpc ? 0 : 1
  security_group_id            = aws_security_group.gateway.id
  referenced_security_group_id = aws_security_group.appserv.id
  from_port                    = local.srpc_range_from
  to_port                      = local.srpc_range_to
  ip_protocol                  = "tcp"
  description                  = "SRPC from HUB (PORT_RANGE must be pinned to this range)"
}
resource "aws_vpc_security_group_ingress_rule" "gateway_srpc_from_appserv_cidr" {
  count             = local.region_dedicated_vpc ? 1 : 0
  security_group_id = aws_security_group.gateway.id
  cidr_ipv4         = var.vpc_cidr
  from_port         = local.srpc_range_from
  to_port           = local.srpc_range_to
  ip_protocol       = "tcp"
  description       = "SRPC from HUB VPC (dedicated mode; PORT_RANGE must be pinned to this range)"
}

output "security_group_ids" {
  value = {
    appserv   = aws_security_group.appserv.id
    dataserv  = aws_security_group.dataserv.id
    gcserv    = aws_security_group.gcserv.id
    blockserv = aws_security_group.blockserv.id
    gateway   = aws_security_group.gateway.id
  }
}
