variable "model_id" {
  description = "HuggingFace model identifier to serve."
  type        = string
}

variable "quantization" {
  description = "Quantization method, or null for full precision."
  type        = string
  default     = null
}

variable "max_replicas" {
  description = "Upper bound on serving replicas."
  type        = number
  default     = 3
}

variable "gpu_taint_key" {
  description = "Taint key the serving pods must tolerate to land on GPU nodes."
  type        = string
  default     = "nvidia.com/gpu"
}

variable "tags" {
  type    = map(string)
  default = {}
}
