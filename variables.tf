variable "cluster_name" {
  description = "Name of the EKS cluster."
  type        = string
}

variable "region" {
  description = "AWS region. GPU capacity varies by region; us-west-2 and us-east-1 have the widest g5/g6 availability."
  type        = string
  default     = "us-west-2"
}

variable "gpu_instance_types" {
  description = "Ordered preference list for GPU nodes. Karpenter falls through to the next type when capacity is unavailable."
  type        = list(string)
  default     = ["g5.xlarge", "g5.2xlarge", "g6.xlarge"]
}

variable "capacity_type" {
  description = "spot or on-demand. Spot cuts GPU cost substantially but nodes can be reclaimed with a 2-minute warning."
  type        = string
  default     = "spot"

  validation {
    condition     = contains(["spot", "on-demand"], var.capacity_type)
    error_message = "capacity_type must be spot or on-demand."
  }
}

variable "model_id" {
  description = "HuggingFace model identifier served by vLLM."
  type        = string
  default     = "meta-llama/Llama-3.1-8B-Instruct"
}

variable "quantization" {
  description = "Quantization method. awq fits an 8B model on a single 24GB GPU; null serves at full precision."
  type        = string
  default     = "awq"
}

variable "max_replicas" {
  description = "Upper bound for the serving deployment. Guards against a runaway autoscaler on expensive nodes."
  type        = number
  default     = 3
}

variable "enable_observability" {
  description = "Deploy the kube-prometheus-stack and GPU metrics exporters."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to all resources. Cost allocation depends on these."
  type        = map(string)
  default     = {}
}

variable "node_iam_role_name" {
  description = "IAM role assumed by Karpenter-provisioned GPU nodes."
  type        = string
}
