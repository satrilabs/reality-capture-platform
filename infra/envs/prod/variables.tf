variable "cost_center" {
  description = "Cost center charged for the platform."
  type        = string
}

variable "edge_regions" {
  description = "Data region => API hosts of that region's stamp."
  type = map(object({
    origin_hosts = list(string)
  }))
}
