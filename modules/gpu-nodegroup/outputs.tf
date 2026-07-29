output "node_pool_name" {
  description = "Karpenter NodePool name. Target it from a workload with a nodeSelector or affinity rule."
  value       = "gpu"
}

output "gpu_taint" {
  description = "Taint applied to GPU nodes. Serving workloads must tolerate this."
  value = {
    key    = local.gpu_taint_key
    value  = "true"
    effect = "NoSchedule"
  }
}

output "gpu_operator_namespace" {
  description = "Namespace hosting the NVIDIA GPU Operator and the DCGM exporter."
  value       = helm_release.gpu_operator.namespace
}

output "estimated_hourly_cost_usd" {
  description = "Estimated hourly cost for one node of the cheapest listed instance type. Planning figure only."
  value       = local.estimated_hourly
}
