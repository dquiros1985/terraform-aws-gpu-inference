output "public_ip" {
  value = aws_instance.bench.public_ip
}

output "endpoint" {
  value = "http://${aws_instance.bench.public_ip}:8000"
}

output "terminates_at_utc" {
  description = "Hard deadline. The instance terminates itself at this time regardless of state."
  value       = timeadd(timestamp(), "${var.max_runtime_minutes}m")
}

output "estimated_max_cost_usd" {
  description = "Worst case for the full window at roughly $0.35/hr spot. Confirm against Cost Explorer."
  value       = format("~$%.2f", (var.max_runtime_minutes / 60.0) * 0.35)
}

output "next_steps" {
  value = "Model load takes ~3-5 min. Then: bash benchmark.sh <public_ip>. Finish early with: terraform destroy -auto-approve"
}
