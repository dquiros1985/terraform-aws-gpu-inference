variable "monthly_budget_usd" {
  description = "Hard monthly budget. Alerts fire at 50/80/100 percent of this."
  type        = number
  default     = 25
}

variable "alert_email" {
  description = "Address that receives budget alerts. Confirm the SNS subscription email or alerts go nowhere."
  type        = string
}

variable "cluster_name" {
  description = "Used to scope the budget filter by tag."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
