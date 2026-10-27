# ──────────────────────────────────────────────────────────────
# Quest load balancer — internet-facing ALB with HTTPS on rearcquest.com
# ──────────────────────────────────────────────────────────────

resource "aws_security_group" "alb" {
  name        = "quest-alb"
  description = "Quest ALB: HTTP and HTTPS from anywhere, out only to the tasks"
  vpc_id      = module.vpc.vpc_id

  tags = merge(local.tags, { Name = "quest-alb" })
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP, redirected to HTTPS"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_tasks" {
  security_group_id            = aws_security_group.alb.id
  description                  = "App port on the tasks"
  ip_protocol                  = "tcp"
  from_port                    = 3000
  to_port                      = 3000
  referenced_security_group_id = aws_security_group.tasks.id
}

resource "aws_lb" "quest" {
  name               = "quest"
  internal           = false
  load_balancer_type = "application"
  subnets            = module.vpc.public_subnets
  security_groups    = [aws_security_group.alb.id]

  drop_invalid_header_fields = true

  tags = local.tags
}

resource "aws_lb_target_group" "quest" {
  name                 = "quest"
  port                 = 3000
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = module.vpc.vpc_id
  deregistration_delay = 30

  # /docker answers from inside the container. / would make bin/001 fetch
  # www.rearc.io on every probe, tying both targets' health to that site.
  health_check {
    path                = "/docker"
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = local.tags
}

# TLS 1.3 and 1.2 only — AWS's recommended policy for ALB HTTPS listeners.
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.quest.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.quest.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.quest.arn
  }

  tags = local.tags
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.quest.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      protocol    = "HTTPS"
      port        = "443"
      status_code = "HTTP_301"
    }
  }

  tags = local.tags
}

resource "aws_route53_record" "apex" {
  zone_id = aws_route53_zone.quest.zone_id
  name    = "rearcquest.com"
  type    = "A"

  alias {
    name                   = aws_lb.quest.dns_name
    zone_id                = aws_lb.quest.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "www" {
  zone_id = aws_route53_zone.quest.zone_id
  name    = "www.rearcquest.com"
  type    = "A"

  alias {
    name                   = aws_lb.quest.dns_name
    zone_id                = aws_lb.quest.zone_id
    evaluate_target_health = true
  }
}

output "alb_dns_name" {
  description = "DNS name of the quest ALB."
  value       = aws_lb.quest.dns_name
}
