# ──────────────────────────────────────────────────────────────
# DNS and TLS — Route 53 zone and ACM certificate for rearcquest.com
# ──────────────────────────────────────────────────────────────

# rearcquest.com is registered through DNSimple. Its name servers at DNSimple
# are pointed at this zone's four name servers (output route53_name_servers)
# by hand, once, outside Terraform — the registrar delegation is not managed
# here. Confirm with `dig NS rearcquest.com`. Destroying and re-creating this
# zone assigns new name servers, so the DNSimple delegation must be redone.
resource "aws_route53_zone" "quest" {
  name = "rearcquest.com"

  tags = local.tags
}

# Same region as the provider (us-east-2) because it is attached to the ALB
# there, not to CloudFront.
resource "aws_acm_certificate" "quest" {
  domain_name               = "rearcquest.com"
  subject_alternative_names = ["www.rearcquest.com"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = local.tags
}

resource "aws_route53_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.quest.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  zone_id         = aws_route53_zone.quest.zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]
}

# The first apply waits here until the DNSimple name-server change has
# propagated: ACM can only see the validation records once public resolvers
# follow the delegation to this zone. If the delegation is not in place, this
# times out after 45 minutes and the apply fails.
resource "aws_acm_certificate_validation" "quest" {
  certificate_arn         = aws_acm_certificate.quest.arn
  validation_record_fqdns = [for record in aws_route53_record.acm_validation : record.fqdn]

  timeouts {
    create = "45m"
  }
}

output "route53_name_servers" {
  description = "Name servers of the rearcquest.com zone; set these at DNSimple."
  value       = aws_route53_zone.quest.name_servers
}

# Taken from the validation resource, not the certificate, so anything that
# consumes it (the ALB listener) waits until the certificate is ISSUED.
output "acm_certificate_arn" {
  description = "ARN of the issued rearcquest.com certificate."
  value       = aws_acm_certificate_validation.quest.certificate_arn
}
