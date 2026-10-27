variable "data_region" {
  description = "Data residency region of the customers this stamp serves."
  type        = string

  validation {
    condition     = contains(["eu", "us"], var.data_region)
    error_message = "data_region must be eu or us."
  }
}

variable "location" {
  description = "Azure region for the stamp, for example westeurope."
  type        = string
}

variable "environment" {
  description = "Environment name, for example prod or dev."
  type        = string
}

variable "address_space" {
  description = "VNet range for the stamp. Must not overlap with other stamps."
  type        = string
}

variable "tags" {
  description = "Tags for every resource. Must include owner and cost-center."
  type        = map(string)

  validation {
    condition     = alltrue([for key in ["owner", "cost-center"] : contains(keys(var.tags), key)])
    error_message = "tags must include owner and cost-center."
  }
}

variable "cool_after_days" {
  description = "Days without access before a scan moves to the cool tier."
  type        = number
  default     = 30
}

variable "cold_after_days" {
  description = "Days without access before a scan moves to the cold tier."
  type        = number
  default     = 90
}

variable "log_daily_quota_gb" {
  description = "Daily log ingestion cap, so a noisy service cannot run up the bill."
  type        = number
  default     = 5
}
