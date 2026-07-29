# ---------------------------------------------------------------------------
# Cost guardrails.
#
# These do NOT cap spend - AWS has no hard spending cap. They tell you fast.
# The only reliable cost control for this stack is `terraform destroy`, which
# is why scripts/teardown.sh exists and why the README leads with it.
#
# Budget alerts are evaluated a few times a day, not in real time. Treat them
# as a safety net for a forgotten cluster, not as protection against a bad
# apply. For that, read the plan.
# ---------------------------------------------------------------------------

resource "aws_sns_topic" "budget_alerts" {
  name = "${var.cluster_name}-budget-alerts"
  tags = var.tags
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.budget_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_budgets_budget" "monthly" {
  name         = "${var.cluster_name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Warn early. By the time actual spend hits 100 percent the money is gone,
  # so the forecast threshold is the one that actually saves you.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_sns_topic_arns  = [aws_sns_topic.budget_alerts.arn]
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_sns_topic_arns  = [aws_sns_topic.budget_alerts.arn]
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_sns_topic_arns  = [aws_sns_topic.budget_alerts.arn]
    subscriber_email_addresses = [var.alert_email]
  }
}
