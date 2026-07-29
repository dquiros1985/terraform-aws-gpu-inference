# Rough hourly cost at one node of the cheapest listed instance type.
#
# Deliberately an estimate from a static table rather than the Pricing API:
# the number exists to make cost visible at plan time, not to be authoritative.
# Confirm actual spend in Cost Explorer.
locals {
  # On-demand USD/hour, us-west-2, as of 2026-07. Update when adding types.
  hourly_on_demand = {
    "g5.xlarge"  = 1.006
    "g5.2xlarge" = 1.212
    "g6.xlarge"  = 0.805
    "g6.2xlarge" = 0.978
  }

  known_types = [for t in var.instance_types : t if contains(keys(local.hourly_on_demand), t)]

  cheapest_hourly = length(local.known_types) > 0 ? min([
    for t in local.known_types : local.hourly_on_demand[t]
  ]...) : null

  # Spot typically runs 60-70% below on-demand for these families, but the
  # discount floats. 0.35 is a conservative planning figure, not a quote.
  estimated_hourly = local.cheapest_hourly == null ? null : (
    var.capacity_type == "spot" ? local.cheapest_hourly * 0.35 : local.cheapest_hourly
  )
}
