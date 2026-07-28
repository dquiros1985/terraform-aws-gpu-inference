output "cluster_name" {
  description = "EKS cluster name."
  value       = var.cluster_name
}

output "inference_endpoint" {
  description = "OpenAI-compatible endpoint exposed by vLLM."
  value       = try(module.vllm_serving.endpoint, null)
}

output "grafana_url" {
  description = "Grafana URL when observability is enabled."
  value       = try(module.observability[0].grafana_url, null)
}

output "estimated_hourly_cost_usd" {
  description = "Rough hourly cost at minimum replica count. Estimate only - confirm against Cost Explorer."
  value       = try(module.gpu_nodegroup.estimated_hourly_cost_usd, null)
}
