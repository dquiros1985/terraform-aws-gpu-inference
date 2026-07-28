# ---------------------------------------------------------------------------
# terraform-aws-gpu-inference
#
# Stands up an EKS cluster with GPU capacity and serves an LLM through vLLM,
# with autoscaling and observability wired in. One apply, one destroy.
#
# The point of this module is that GPU inference infrastructure should be as
# reproducible as any other workload. Notebooks and one-off scripts do not
# survive a team.
# ---------------------------------------------------------------------------

locals {
  tags = merge(var.tags, {
    ManagedBy = "terraform"
    Module    = "terraform-aws-gpu-inference"
  })
}

# TODO: VPC. Use terraform-aws-modules/vpc/aws rather than hand-rolling.
#       GPU subnets need adequate IP space; a /24 per AZ runs out fast when
#       pods get VPC IPs.

# TODO: EKS control plane. terraform-aws-modules/eks/aws.
#       Pin the Kubernetes version explicitly - GPU device plugin
#       compatibility is version-sensitive.

module "gpu_nodegroup" {
  source = "./modules/gpu-nodegroup"

  cluster_name   = var.cluster_name
  instance_types = var.gpu_instance_types
  capacity_type  = var.capacity_type
  tags           = local.tags

  # TODO: Karpenter provisioner + NVIDIA GPU Operator.
  #       The GPU Operator installs drivers, the container toolkit and the
  #       device plugin. Installing drivers by hand in a launch template is
  #       the classic mistake here - it breaks on every AMI update.
}

module "vllm_serving" {
  source = "./modules/vllm-serving"

  model_id     = var.model_id
  quantization = var.quantization
  max_replicas = var.max_replicas
  tags         = local.tags

  depends_on = [module.gpu_nodegroup]

  # TODO: vLLM deployment + service + HPA/KEDA.
  #       Scale on queue depth or tokens/sec, not CPU. CPU utilisation is
  #       close to meaningless for GPU-bound inference.
  # TODO: readiness probe must wait for model load. An 8B model takes
  #       60-120s to load; a default probe will restart-loop forever.
}

module "observability" {
  source = "./modules/observability"
  count  = var.enable_observability ? 1 : 0

  cluster_name = var.cluster_name
  tags         = local.tags

  # TODO: kube-prometheus-stack + DCGM exporter + Grafana dashboards.
  #       Track tokens/sec, time-to-first-token, p50/p95/p99 latency,
  #       GPU utilisation, GPU memory and cost per million tokens.
}
