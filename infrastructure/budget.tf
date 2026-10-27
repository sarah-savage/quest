# ──────────────────────────────────────────────────────────────
# Spend tripwire — AWS Budgets email alerts
#
# The quest bills by the hour (NAT gateway, ALB, Fargate), so a $100/month
# cost budget emails at $40 and $50 of actual spend and at $100 of forecasted
# spend for the month.
# ──────────────────────────────────────────────────────────────

variable "budget_alert_email" {
  description = "Address that receives the quest budget alerts. Set on the quest Terraform Cloud workspace, not committed, because this repository is public."
  type        = string

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.budget_alert_email))
    error_message = "budget_alert_email must be an email address, such as name@example.com."
  }
}

resource "aws_budgets_budget" "quest_monthly" {
  name         = "quest-monthly"
  budget_type  = "COST"
  limit_amount = "100"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # $40 of actual spend.
  notification {
    comparison_operator        = "GREATER_THAN"
    notification_type          = "ACTUAL"
    threshold                  = 40
    threshold_type             = "PERCENTAGE"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  # $50 of actual spend.
  notification {
    comparison_operator        = "GREATER_THAN"
    notification_type          = "ACTUAL"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  # $100 of forecasted spend for the month.
  notification {
    comparison_operator        = "GREATER_THAN"
    notification_type          = "FORECASTED"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  tags = local.tags
}
