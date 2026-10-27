variable "environment" {
  type = string
}

variable "resource_group_name" {
  description = "Resource group for the global resources."
  type        = string
}

variable "regions" {
  description = "Data region => the API hosts of that region's stamp."
  type = map(object({
    origin_hosts = list(string)
  }))
}

variable "tags" {
  type = map(string)
}
