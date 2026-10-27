# ──────────────────────────────────────────────────────────────
# Quest VPC — two AZs, public + private subnets, one NAT gateway
# ──────────────────────────────────────────────────────────────

data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.3"

  name = local.vpc_name
  cidr = local.vpc_cidr

  manage_default_security_group = true
  manage_default_route_table    = true
  manage_default_network_acl    = true

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]

  private_subnet_enable_resource_name_dns_a_record_on_launch = true
  private_subnet_private_dns_hostname_type_on_launch         = "resource-name"

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  enable_flow_log                                 = true
  create_flow_log_cloudwatch_iam_role             = true
  create_flow_log_cloudwatch_log_group            = true
  flow_log_cloudwatch_log_group_retention_in_days = 7
  flow_log_log_format                             = "$${version} $${account-id} $${interface-id} $${srcaddr} $${srcport} $${protocol} $${packets} $${bytes} $${start} $${end} $${action} $${log-status} $${traffic-path} $${flow-direction} $${pkt-dstaddr} $${pkt-srcaddr} $${dstaddr} $${dstport}"

  tags = local.tags
}
