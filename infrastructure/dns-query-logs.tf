# ──────────────────────────────────────────────────────────────
# Route 53 Resolver query logging for the quest VPC
#
# The VPC flow logs (vpc.tf) record only IP addresses and ports. The quest
# runs opaque binaries, and an IP does not say what they meant to reach.
# Resolver query logs record every DNS name looked up from inside the VPC, so
# they show whether the binaries contact anything besides cloud metadata and
# AWS service endpoints — including data leaking out through the lookups
# themselves (DNS exfiltration), which never opens a connection and so never
# shows up as a flow to anywhere but the VPC resolver.
# ──────────────────────────────────────────────────────────────

data "aws_caller_identity" "query_logs" {}

resource "aws_cloudwatch_log_group" "resolver_query_logs" {
  name              = "/aws/route53resolver/${local.vpc_name}"
  retention_in_days = 7

  tags = local.tags
}

# Resolver query logs are CloudWatch "vended logs" (V1 permissions model):
# delivery.logs.amazonaws.com writes them, and the log group must carry a
# resource policy letting it do so. If none exists, AWS creates one itself
# when the logging is set up — outside Terraform, invisible to the plan and
# left behind on destroy. Declaring it here first means AWS finds the policy
# already in place and does not add its own. The statement mirrors the one AWS
# would create (CloudWatch Logs User Guide, "Logs sent to CloudWatch Logs",
# https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/AWS-logs-infrastructure-CWL.html;
# the destinations table there lists Route 53 resolver query logs as V1).
#
# Scoped to this one log group (resource_arn, needs hashicorp/aws >= 6.36.0;
# the lock file pins 6.70.0) rather than an account-level policy, which is
# limited to 10 per region and would grant more than one group.
resource "aws_cloudwatch_log_resource_policy" "resolver_query_logs" {
  resource_arn = aws_cloudwatch_log_group.resolver_query_logs.arn

  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSLogDeliveryWrite"
        Effect = "Allow"
        Principal = {
          Service = "delivery.logs.amazonaws.com"
        }
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.resolver_query_logs.arn}:log-stream:*"
        # Only deliveries on behalf of this account (confused-deputy guard).
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.query_logs.account_id
          }
          ArnLike = {
            "aws:SourceArn" = "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.query_logs.account_id}:*"
          }
        }
      },
    ]
  })
}

resource "aws_route53_resolver_query_log_config" "quest" {
  name            = "${local.vpc_name}-dns"
  destination_arn = aws_cloudwatch_log_group.resolver_query_logs.arn

  # The policy must exist before the log delivery is set up, or AWS creates
  # its own (see above).
  depends_on = [aws_cloudwatch_log_resource_policy.resolver_query_logs]

  tags = local.tags
}

resource "aws_route53_resolver_query_log_config_association" "quest" {
  resolver_query_log_config_id = aws_route53_resolver_query_log_config.quest.id
  resource_id                  = module.vpc.vpc_id
}
