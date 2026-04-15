variable "subscription_id" { type = string }
variable "resource_group" {
  type    = string
  default = "alex-rg"
}
variable "location" {
  type    = string
  default = "eastus"
}

variable "notification_email" { type = string }

variable "api_container_app_id" {
  description = "Resource id of alex-api Container App"
  type        = string
}

variable "api_fqdn" {
  description = "FQDN of alex-api (for uptime check)"
  type        = string
}

variable "postgres_server_id" {
  description = "Resource id of the PostgreSQL Flexible Server"
  type        = string
}

variable "servicebus_namespace_id" {
  description = "Resource id of the Service Bus namespace"
  type        = string
}

variable "openai_account_id" {
  description = "Resource id of the Cognitive Services / Azure OpenAI account"
  type        = string
}

variable "agent_function_app_ids" {
  description = "List of Function app resource ids for per-agent metric alerts"
  type        = list(string)
  default     = []
}

variable "key_vault_id" { type = string }

variable "enable_content_safety" {
  type    = bool
  default = true
}
