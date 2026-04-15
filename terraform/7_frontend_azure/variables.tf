variable "subscription_id" { type = string }
variable "resource_group" {
  type    = string
  default = "alex-rg"
}
variable "location" {
  type    = string
  default = "eastus"
}

variable "frontend_host" {
  description = "swa | storage"
  type        = string
  default     = "swa"
  validation {
    condition     = contains(["swa", "storage"], var.frontend_host)
    error_message = "frontend_host must be 'swa' or 'storage'"
  }
}

variable "frontend_domain" {
  type    = string
  default = ""
}

variable "clerk_jwks_url" { type = string }
variable "clerk_issuer" {
  type    = string
  default = ""
}

variable "api_container_image" {
  description = "Container Apps image for alex-api; leave blank for placeholder"
  type        = string
  default     = ""
}

variable "container_app_environment_id" {
  description = "Reuse the environment from guide 4"
  type        = string
}

variable "acr_id" {
  description = "Azure Container Registry resource id"
  type        = string
}

variable "servicebus_namespace" {
  description = "From guide 6"
  type        = string
}

variable "servicebus_queue" {
  type    = string
  default = "alex-agent-jobs"
}

variable "postgres_host" { type = string }
variable "db_secret_uri" { type = string }
variable "key_vault_id" { type = string }

variable "azure_openai_endpoint" { type = string }
variable "azure_openai_deployment" {
  type    = string
  default = "gpt-4o"
}
