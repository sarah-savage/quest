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

# ──────────────────────────────────────────────────────────────
# S3 gateway endpoint — keeps ECR layer pulls off the NAT gateway
# ──────────────────────────────────────────────────────────────
#
# ECR stores image layers in S3, so without this every Fargate image pull
# from the private subnets crosses the NAT gateway and pays its per-GB data
# charge. Gateway endpoints are free and route S3 traffic over the AWS network.
#
# The ECR API and DKR interface endpoints are deliberately omitted: they cost
# about $29/month for two AZs, so those (small) calls still go through the NAT.
#
# No policy is set, so the endpoint keeps AWS's default full-access policy. A
# restrictive policy could block the ECR layer bucket and break image pulls.

data "aws_region" "current" {}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  tags = merge(local.tags, { Name = "${local.vpc_name}-s3" })
}
