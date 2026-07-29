variable "cluster_name" {
  description = "EKS cluster name, used to label metrics and name dashboards."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
