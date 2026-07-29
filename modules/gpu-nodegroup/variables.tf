variable "cluster_name" {
  description = "EKS cluster name. Must match the karpenter.sh/discovery tag on subnets and security groups."
  type        = string
}

variable "node_iam_role_name" {
  description = "IAM role assumed by Karpenter-provisioned nodes."
  type        = string
}

variable "instance_types" {
  description = <<-EOT
    Ordered preference list for GPU instances. Breadth matters more than
    precision here: GPU spot capacity is scarce and regional, and a NodePool
    pinned to a single instance type will simply fail to provision when that
    type is unavailable in the AZ.
  EOT
  type        = list(string)
  default     = ["g5.xlarge", "g5.2xlarge", "g6.xlarge", "g6.2xlarge"]
}

variable "capacity_type" {
  description = "spot or on-demand. Karpenter falls back to on-demand when both are listed and spot is unavailable."
  type        = string
  default     = "spot"

  validation {
    condition     = contains(["spot", "on-demand"], var.capacity_type)
    error_message = "capacity_type must be spot or on-demand."
  }
}

variable "gpu_operator_version" {
  description = "NVIDIA GPU Operator chart version. Pin it: driver and toolkit compatibility is version-sensitive."
  type        = string
  default     = "v24.9.1"
}

variable "ami_alias" {
  description = <<-EOT
    Karpenter AMI alias. Pin to a dated version rather than `latest` so node
    replacement is a deliberate act - an AMI that rolls underneath you will
    eventually roll during an incident.
  EOT
  type        = string
  default     = "al2023@latest"
}

variable "disk_size_gi" {
  description = <<-EOT
    Root volume size. Model weights are large: an 8B model in AWQ is roughly
    5-6 GB and the container images are several GB more. The 20Gi default of
    most examples fills immediately and the failure looks like an image pull
    error rather than a disk problem.
  EOT
  type        = number
  default     = 200
}

variable "cpu_limit" {
  description = "Upper bound on total vCPU across the NodePool. The safety rail against a runaway autoscaler on GPU pricing."
  type        = number
  default     = 64
}

variable "tags" {
  description = "Tags propagated to provisioned EC2 instances. Cost allocation depends on these."
  type        = map(string)
  default     = {}
}
