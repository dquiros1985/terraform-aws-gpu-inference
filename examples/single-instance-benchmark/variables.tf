variable "region" {
  type    = string
  default = "us-west-2"
}

variable "max_runtime_minutes" {
  description = <<-EOT
    Deadman switch. The instance schedules its own shutdown this many minutes
    after boot, and shutdown means terminate. It fires even if the benchmark
    hangs, SSH breaks, or you close the laptop and forget - which is the whole
    point. Cost is bounded by this number, not by your memory.
  EOT
  type        = number
  default     = 120

  validation {
    condition     = var.max_runtime_minutes > 0 && var.max_runtime_minutes <= 480
    error_message = "Keep it between 1 and 480 minutes. Longer than 8 hours defeats the purpose."
  }
}

variable "instance_type" {
  description = "g5.xlarge is one A10G (24GB), enough for a 7-8B model in AWQ."
  type        = string
  default     = "g5.xlarge"
}

variable "max_spot_price_usd" {
  description = "Ceiling per hour as a string, e.g. \"0.50\". Null accepts the prevailing spot price."
  type        = string
  default     = null
}

variable "model_id" {
  description = "HuggingFace model served by vLLM. Use an AWQ build to fit 24GB comfortably."
  type        = string
  default     = "TheBloke/Llama-2-7B-Chat-AWQ"
}

variable "allowed_cidr" {
  description = "Who may reach the inference port. Set this to your own IP/32 - the default reaches nothing."
  type        = string
  default     = "127.0.0.1/32"
}

variable "preflight_quota_check" {
  description = <<-EOT
    Check the account's G-family spot quota during plan, before anything is
    created. A fresh AWS account is allowed zero GPU vCPUs and the runtime
    error for that is misleading, so this turns it into a readable plan-time
    failure. Needs servicequotas:GetServiceQuota - set false if the caller
    lacks that permission.
  EOT
  type        = bool
  default     = true
}

variable "key_name" {
  description = "Existing EC2 key pair for SSH. Optional."
  type        = string
  default     = null
}
