variable "subscription_id" { type = string }
variable "resource_group" {
  type    = string
  default = "alex-rg"
}
variable "location" {
  type    = string
  default = "eastus"
}

variable "db_sku" {
  type    = string
  default = "B_Standard_B1ms"
}

variable "db_storage_mb" {
  type    = number
  default = 32768
}

variable "db_admin_user" {
  type    = string
  default = "alex_admin"
}

variable "db_admin_password" {
  description = "Leave empty to auto-generate (must meet Azure complexity rules)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "client_ip" {
  description = "Your current public IP to allow through the firewall. Leave empty to auto-detect."
  type        = string
  default     = ""
}

variable "allow_all_azure_services" {
  type    = bool
  default = true
}
