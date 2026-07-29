output "sns_topic_arn" {
  description = "Topic receiving budget alerts."
  value       = aws_sns_topic.budget_alerts.arn
}

output "reminder" {
  description = "What these guardrails do not do."
  value       = "Budget alerts notify, they do not cap. Run scripts/teardown.sh when finished."
}
