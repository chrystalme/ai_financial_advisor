variable "subscription_id" { type = string }
variable "resource_group" {
  type    = string
  default = "alex-rg"
}
variable "location" {
  type    = string
  default = "eastus"
}

variable "azure_openai_endpoint" { type = string }
variable "azure_openai_key" {
  type      = string
  sensitive = true
}
variable "azure_openai_deployment" {
  type    = string
  default = "gpt-4o"
}

variable "alex_api_endpoint" { type = string }
variable "alex_api_key" {
  type      = string
  sensitive = true
}

variable "container_image" {
  description = "ACR image for the researcher; leave blank to use a placeholder until first push"
  type        = string
  default     = ""
}

variable "min_replicas" {
  type    = number
  default = 0
}

variable "max_replicas" {
  type    = number
  default = 3
}

variable "scheduler_enabled" {
  type    = bool
  default = false
}

variable "schedule_cron" {
  type    = string
  default = "0 */6 * * *"
}
