# Network layer (owner: Mohamed Ayad): one VPC in 2 zones with public, app and db tiers.

locals {
  name_prefix = "secure-aws"

  vpc_cidr = "10.0.0.0/16"

  azs = {
    a = sort(data.aws_availability_zones.available.names)[0]
    b = sort(data.aws_availability_zones.available.names)[1]
  }

  public_subnet_cidrs = {
    a = "10.0.1.0/24"
    b = "10.0.2.0/24"
  }

  app_subnet_cidrs = {
    a = "10.0.11.0/24"
    b = "10.0.12.0/24"
  }

  db_subnet_cidrs = {
    a = "10.0.21.0/24"
    b = "10.0.22.0/24"
  }

  db_port  = 3306 # RDS MySQL
  app_port = 8080

  any_ipv4       = "0.0.0.0/0"
  ssm_endpoints  = ["ssm", "ssmmessages", "ec2messages"]
  endpoints_port = var.enable_interface_endpoints ? 443 : null
}

data "aws_region" "current" {}

# Normal AZs only, no Local Zones.
data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# --- VPC -----------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = local.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.name_prefix}-main-vpc"
  }
}

# Removes all rules from the default security group (CIS).
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-default-sg-do-not-use"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-igw"
  }
}

# --- Subnets: 3 tiers x 2 zones ------------------------------------------------

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.public_subnet_cidrs.a
  availability_zone       = local.azs.a
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name_prefix}-public-a"
  }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.public_subnet_cidrs.b
  availability_zone       = local.azs.b
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name_prefix}-public-b"
  }
}

resource "aws_subnet" "private_app_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.app_subnet_cidrs.a
  availability_zone = local.azs.a

  tags = {
    Name = "${local.name_prefix}-app-a"
  }
}

resource "aws_subnet" "private_app_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.app_subnet_cidrs.b
  availability_zone = local.azs.b

  tags = {
    Name = "${local.name_prefix}-app-b"
  }
}

resource "aws_subnet" "private_db_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.db_subnet_cidrs.a
  availability_zone = local.azs.a

  tags = {
    Name = "${local.name_prefix}-db-a"
  }
}

resource "aws_subnet" "private_db_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.db_subnet_cidrs.b
  availability_zone = local.azs.b

  tags = {
    Name = "${local.name_prefix}-db-b"
  }
}

locals {
  public_subnet_ids = { a = aws_subnet.public_a.id, b = aws_subnet.public_b.id }
  app_subnet_ids    = { a = aws_subnet.private_app_a.id, b = aws_subnet.private_app_b.id }
  db_subnet_ids     = { a = aws_subnet.private_db_a.id, b = aws_subnet.private_db_b.id }
}

# --- Routing -------------------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-public-rt"
  }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = local.any_ipv4
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  for_each = local.public_subnet_ids

  subnet_id      = each.value
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "app" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-app-rt"
  }
}

resource "aws_route" "app_internet" {
  count = var.enable_nat_gateway ? 1 : 0

  route_table_id         = aws_route_table.app.id
  destination_cidr_block = local.any_ipv4
  nat_gateway_id         = aws_nat_gateway.main[0].id
}

resource "aws_route_table_association" "app" {
  for_each = local.app_subnet_ids

  subnet_id      = each.value
  route_table_id = aws_route_table.app.id
}

# Local route only: no way out of the VPC.
resource "aws_route_table" "db" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-db-rt"
  }
}

resource "aws_route_table_association" "db" {
  for_each = local.db_subnet_ids

  subnet_id      = each.value
  route_table_id = aws_route_table.db.id
}

# --- NAT Gateway ---------------------------------------------------------------
# One NAT in zone a to save cost; production would run one per zone.

resource "aws_eip" "nat" {
  count = var.enable_nat_gateway ? 1 : 0

  domain = "vpc"

  tags = {
    Name = "${local.name_prefix}-nat-eip"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  count = var.enable_nat_gateway ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public_a.id

  tags = {
    Name = "${local.name_prefix}-nat-a"
  }

  depends_on = [aws_internet_gateway.main]
}

# --- VPC endpoints -------------------------------------------------------------

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.app.id]

  tags = {
    Name = "${local.name_prefix}-s3-endpoint"
  }
}

# Looked up by name so its CIDRs are known at plan time (used by the app NACL).
data "aws_prefix_list" "s3" {
  name = "com.amazonaws.${data.aws_region.current.region}.s3"
}

resource "aws_vpc_endpoint" "ssm" {
  for_each = var.enable_interface_endpoints ? toset(local.ssm_endpoints) : toset([])

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = values(local.app_subnet_ids)
  security_group_ids  = [aws_security_group.endpoints[0].id]
  private_dns_enabled = true

  tags = {
    Name = "${local.name_prefix}-${each.key}-endpoint"
  }
}

# --- Security groups -----------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "ALB security group"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-alb-sg"
  }
}

# HTTP 80 only for the current demo; HTTPS comes later. It will need 443 here and in the
# public NACL, separate from the NAT switch, from the same approved IPs.
resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  for_each = toset(var.allowed_ingress_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "HTTP from approved test IPs"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = each.value
}

# ICMP type 3 code 4 ("fragmentation needed") for Path MTU Discovery.
resource "aws_vpc_security_group_ingress_rule" "alb_pmtud" {
  security_group_id = aws_security_group.alb.id
  description       = "Path MTU Discovery"
  ip_protocol       = "icmp"
  from_port         = 3
  to_port           = 4
  cidr_ipv4         = local.any_ipv4
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  count = local.app_port == null ? 0 : 1

  security_group_id            = aws_security_group.alb.id
  description                  = "To app servers on the app port"
  ip_protocol                  = "tcp"
  from_port                    = local.app_port
  to_port                      = local.app_port
  referenced_security_group_id = aws_security_group.app.id
}

# No SSH. Session Manager needs the NAT or the SSM endpoints: with both off it cannot reach
# the instances. Compute must also give them an instance profile and the SSM Agent.
resource "aws_security_group" "app" {
  name        = "${local.name_prefix}-app-sg"
  description = "App security group"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-app-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  count = local.app_port == null ? 0 : 1

  security_group_id            = aws_security_group.app.id
  description                  = "App port from the load balancer only"
  ip_protocol                  = "tcp"
  from_port                    = local.app_port
  to_port                      = local.app_port
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_egress_rule" "app_to_s3" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS to S3 through the gateway endpoint"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  prefix_list_id    = aws_vpc_endpoint.s3.prefix_list_id
}

resource "aws_vpc_security_group_egress_rule" "app_http_out" {
  count = var.enable_nat_gateway ? 1 : 0

  security_group_id = aws_security_group.app.id
  description       = "HTTP out through the NAT"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = local.any_ipv4
}

resource "aws_vpc_security_group_egress_rule" "app_https_out" {
  count = var.enable_nat_gateway ? 1 : 0

  security_group_id = aws_security_group.app.id
  description       = "HTTPS out through the NAT"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = local.any_ipv4
}

resource "aws_vpc_security_group_egress_rule" "app_to_db" {
  count = local.db_port == null ? 0 : 1

  security_group_id            = aws_security_group.app.id
  description                  = "To the database on the database port"
  ip_protocol                  = "tcp"
  from_port                    = local.db_port
  to_port                      = local.db_port
  referenced_security_group_id = aws_security_group.db.id
}

# No egress rules: security groups are stateful, so replies still work.
resource "aws_security_group" "db" {
  name        = "${local.name_prefix}-db-sg"
  description = "DB security group"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-db-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  count = local.db_port == null ? 0 : 1

  security_group_id            = aws_security_group.db.id
  description                  = "Database port from app servers only"
  ip_protocol                  = "tcp"
  from_port                    = local.db_port
  to_port                      = local.db_port
  referenced_security_group_id = aws_security_group.app.id
}

resource "aws_security_group" "endpoints" {
  count = var.enable_interface_endpoints ? 1 : 0

  name        = "${local.name_prefix}-endpoints-sg"
  description = "Interface endpoints security group"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-endpoints-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_from_app" {
  count = var.enable_interface_endpoints ? 1 : 0

  security_group_id            = aws_security_group.endpoints[0].id
  description                  = "HTTPS from app servers"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.app.id
}

resource "aws_vpc_security_group_egress_rule" "app_to_endpoints" {
  count = var.enable_interface_endpoints ? 1 : 0

  security_group_id            = aws_security_group.app.id
  description                  = "HTTPS to the interface endpoints"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.endpoints[0].id
}

# Quarantine for incident response: no rules, so no new connections in or out.
resource "aws_security_group" "isolation" {
  name        = "${local.name_prefix}-isolation-sg"
  description = "Isolation security group for incident response"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-isolation-sg"
  }
}

# --- Network ACLs --------------------------------------------------------------

resource "aws_network_acl" "tier" {
  for_each = {
    public = values(local.public_subnet_ids)
    app    = values(local.app_subnet_ids)
    db     = values(local.db_subnet_ids)
  }

  vpc_id     = aws_vpc.main.id
  subnet_ids = each.value

  tags = {
    Name = "${local.name_prefix}-${each.key}-nacl"
  }

  # AWS allows 20 rules per direction by default; the ICMP rule takes one.
  lifecycle {
    precondition {
      condition = alltrue([for e in [true, false] :
      length([for r in values(local.all_nacl_rules) : r if r.nacl == each.key && r.egress == e]) < 20])
      error_message = "The ${each.key} NACL would have more than 20 rules in one direction. Check the number of S3 CIDRs."
    }
  }
}

# Stateless NACLs: replies use 1024-65535 (ALB, NAT) or 32768-65535 (servers; the
# Amazon Linux kernel uses 32768-60999).
# Rules with a null port are skipped (their switch is off).
locals {
  nacl_rules = {
    # Public. NAT-only rules exist only while the NAT is on.
    # NAT replies need 1024-65535 (includes 3389): Security Hub EC2.21 fails while the NAT is on.
    public_in_http        = { nacl = "public", egress = false, rule = 100, from = 80, to = 80, cidr = local.any_ipv4 }
    public_in_https       = { nacl = "public", egress = false, rule = 110, from = var.enable_nat_gateway ? 443 : null, to = 443, cidr = local.any_ipv4 }
    public_in_replies     = { nacl = "public", egress = false, rule = 120, from = var.enable_nat_gateway ? 1024 : null, to = 65535, cidr = local.any_ipv4 }
    public_in_replies_vpc = { nacl = "public", egress = false, rule = 122, from = 1024, to = 65535, cidr = local.vpc_cidr }
    public_out_http       = { nacl = "public", egress = true, rule = 100, from = var.enable_nat_gateway ? 80 : null, to = 80, cidr = local.any_ipv4 }
    public_out_https      = { nacl = "public", egress = true, rule = 110, from = var.enable_nat_gateway ? 443 : null, to = 443, cidr = local.any_ipv4 }
    public_out_replies    = { nacl = "public", egress = true, rule = 120, from = 1024, to = 65535, cidr = local.any_ipv4 }
    public_out_app_a      = { nacl = "public", egress = true, rule = 130, from = local.app_port, to = local.app_port, cidr = local.app_subnet_cidrs.a }
    public_out_app_b      = { nacl = "public", egress = true, rule = 131, from = local.app_port, to = local.app_port, cidr = local.app_subnet_cidrs.b }

    # App. S3 rules are in s3_nacl_rules below.
    app_in_alb_a          = { nacl = "app", egress = false, rule = 100, from = local.app_port, to = local.app_port, cidr = local.public_subnet_cidrs.a }
    app_in_alb_b          = { nacl = "app", egress = false, rule = 101, from = local.app_port, to = local.app_port, cidr = local.public_subnet_cidrs.b }
    app_in_replies        = { nacl = "app", egress = false, rule = 120, from = var.enable_nat_gateway ? 32768 : null, to = 65535, cidr = local.any_ipv4 }
    app_in_replies_db_a   = { nacl = "app", egress = false, rule = 121, from = 32768, to = 65535, cidr = local.db_subnet_cidrs.a }
    app_in_replies_db_b   = { nacl = "app", egress = false, rule = 122, from = 32768, to = 65535, cidr = local.db_subnet_cidrs.b }
    app_in_endpoints_a    = { nacl = "app", egress = false, rule = 140, from = local.endpoints_port, to = local.endpoints_port, cidr = local.app_subnet_cidrs.a }
    app_in_endpoints_b    = { nacl = "app", egress = false, rule = 141, from = local.endpoints_port, to = local.endpoints_port, cidr = local.app_subnet_cidrs.b }
    app_in_replies_ep_a   = { nacl = "app", egress = false, rule = 142, from = local.endpoints_port == null ? null : 32768, to = 65535, cidr = local.app_subnet_cidrs.a }
    app_in_replies_ep_b   = { nacl = "app", egress = false, rule = 143, from = local.endpoints_port == null ? null : 32768, to = 65535, cidr = local.app_subnet_cidrs.b }
    app_out_http          = { nacl = "app", egress = true, rule = 100, from = var.enable_nat_gateway ? 80 : null, to = 80, cidr = local.any_ipv4 }
    app_out_https         = { nacl = "app", egress = true, rule = 110, from = var.enable_nat_gateway ? 443 : null, to = 443, cidr = local.any_ipv4 }
    app_out_replies_alb_a = { nacl = "app", egress = true, rule = 120, from = 1024, to = 65535, cidr = local.public_subnet_cidrs.a }
    app_out_replies_alb_b = { nacl = "app", egress = true, rule = 121, from = 1024, to = 65535, cidr = local.public_subnet_cidrs.b }
    app_out_replies_app_a = { nacl = "app", egress = true, rule = 122, from = local.endpoints_port == null ? null : 1024, to = 65535, cidr = local.app_subnet_cidrs.a }
    app_out_replies_app_b = { nacl = "app", egress = true, rule = 123, from = local.endpoints_port == null ? null : 1024, to = 65535, cidr = local.app_subnet_cidrs.b }
    app_out_db_a          = { nacl = "app", egress = true, rule = 130, from = local.db_port, to = local.db_port, cidr = local.db_subnet_cidrs.a }
    app_out_db_b          = { nacl = "app", egress = true, rule = 131, from = local.db_port, to = local.db_port, cidr = local.db_subnet_cidrs.b }
    app_out_endpoints_a   = { nacl = "app", egress = true, rule = 140, from = local.endpoints_port, to = local.endpoints_port, cidr = local.app_subnet_cidrs.a }
    app_out_endpoints_b   = { nacl = "app", egress = true, rule = 141, from = local.endpoints_port, to = local.endpoints_port, cidr = local.app_subnet_cidrs.b }

    # DB
    db_in_app_a      = { nacl = "db", egress = false, rule = 100, from = local.db_port, to = local.db_port, cidr = local.app_subnet_cidrs.a }
    db_in_app_b      = { nacl = "db", egress = false, rule = 101, from = local.db_port, to = local.db_port, cidr = local.app_subnet_cidrs.b }
    db_out_replies_a = { nacl = "db", egress = true, rule = 100, from = 1024, to = 65535, cidr = local.app_subnet_cidrs.a }
    db_out_replies_b = { nacl = "db", egress = true, rule = 101, from = 1024, to = 65535, cidr = local.app_subnet_cidrs.b }
  }

  # S3 through the gateway endpoint, NAT on or off. NACLs can't use prefix lists, so one rule per S3 CIDR.
  s3_cidrs = sort(data.aws_prefix_list.s3.cidr_blocks)
  s3_nacl_rules = merge(
    { for i, c in local.s3_cidrs : "app_out_s3_${i}" => { nacl = "app", egress = true, rule = 150 + i, from = 443, to = 443, cidr = c } },
    { for i, c in local.s3_cidrs : "app_in_s3_replies_${i}" => { nacl = "app", egress = false, rule = 150 + i, from = 32768, to = 65535, cidr = c } },
  )

  all_nacl_rules = { for name, r in merge(local.nacl_rules, local.s3_nacl_rules) : name => r if r.from != null }
}

resource "aws_network_acl_rule" "tier" {
  for_each = local.all_nacl_rules

  network_acl_id = aws_network_acl.tier[each.value.nacl].id
  egress         = each.value.egress
  rule_number    = each.value.rule
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = each.value.cidr
  from_port      = each.value.from
  to_port        = each.value.to
}

resource "aws_network_acl_rule" "pmtud" {
  for_each = {
    public_in  = { nacl = "public", egress = false }
    public_out = { nacl = "public", egress = true }
    app_in     = { nacl = "app", egress = false }
    app_out    = { nacl = "app", egress = true }
  }

  network_acl_id = aws_network_acl.tier[each.value.nacl].id
  egress         = each.value.egress
  rule_number    = 190
  protocol       = "icmp"
  rule_action    = "allow"
  cidr_block     = local.any_ipv4
  icmp_type      = 3
  icmp_code      = 4
}

# --- VPC Flow Logs -------------------------------------------------------------
# Off by default. Needs the S3 bucket in flow_logs_bucket_arn, whose policy must already let
# delivery.logs.amazonaws.com do s3:PutObject (AWSLogs/aws-account-id=<id>/*) and
# s3:GetBucketAcl; otherwise AWS may replace the bucket policy itself.
# Agree with Kareem and Haitham before turning on. Parquet in S3, for Athena.

locals {
  # Default fields plus the ones incident response needs. To confirm with Haitham.
  flow_log_fields = [
    "version", "account-id", "interface-id", "srcaddr", "dstaddr", "srcport", "dstport",
    "protocol", "packets", "bytes", "start", "end", "action", "log-status",
    "vpc-id", "subnet-id", "instance-id", "tcp-flags", "type", "pkt-srcaddr", "pkt-dstaddr",
    "flow-direction", "traffic-path",
  ]
}

resource "aws_flow_log" "vpc" {
  count = var.enable_flow_logs ? 1 : 0

  vpc_id                   = aws_vpc.main.id
  traffic_type             = "ALL"
  log_destination_type     = "s3"
  log_destination          = var.flow_logs_bucket_arn
  log_format               = join(" ", formatlist("$${%s}", local.flow_log_fields))
  max_aggregation_interval = 60

  destination_options {
    file_format                = "parquet"
    hive_compatible_partitions = true
    per_hour_partition         = true
  }

  tags = {
    Name = "${local.name_prefix}-vpc-flow-logs"
  }

  lifecycle {
    precondition {
      condition     = var.flow_logs_bucket_arn != null
      error_message = "Set flow_logs_bucket_arn before turning on enable_flow_logs."
    }
  }
}
