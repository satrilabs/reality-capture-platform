variable "name" {
  description = "Node pool name, up to 12 lowercase letters and digits (6 for Windows)."
  type        = string
  default     = "agents"
}

variable "kubernetes_cluster_id" {
  description = "AKS cluster that hosts the agents."
  type        = string
}

variable "oidc_issuer_url" {
  description = "OIDC issuer URL of the AKS cluster, for workload identity."
  type        = string
}

variable "subnet_id" {
  description = "Subnet for the agent nodes."
  type        = string
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "container_registry_id" {
  description = "Registry the agents push build images to."
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace of the agent pods."
  type        = string
  default     = "build-agents"
}

variable "os_type" {
  description = "Linux for container builds, Windows for desktop builds."
  type        = string
  default     = "Linux"
}

variable "vm_size" {
  description = "Node size. Compile-heavy builds want many cores and a large ephemeral disk."
  type        = string
  default     = "Standard_D16ds_v5"
}

variable "os_disk_size_gb" {
  type    = number
  default = 300
}

variable "max_nodes" {
  description = "Upper limit on agent nodes, which is also the cost ceiling."
  type        = number
  default     = 20
}

variable "tags" {
  type = map(string)
}
