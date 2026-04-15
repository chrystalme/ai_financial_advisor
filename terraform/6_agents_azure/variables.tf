variable "subscription_id" { type = string }
variable "resource_group" {
  type    = string
  default = "alex-rg"
}
variable "location" {
  type    = string
  default = "eastus"
}

variable "agents" {
  type    = list(string)
  default = ["planner", "tagger", "reporter", "charter", "retirement"]
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
variable "azure_openai_embedding_deployment" {
  type    = string
  default = "text-embedding-3-small"
}

variable "postgres_host" { type = string }
variable "db_secret_uri" {
  description = "Full Key Vault secret URI (https://<kv>.vault.azure.net/secrets/alex-db-credentials)"
  type        = string
}
variable "key_vault_name" { type = string }

variable "azure_search_endpoint" { type = string }
variable "azure_search_key" {
  type      = string
  sensitive = true
}
variable "azure_search_index" {
  type    = string
  default = "alex-docs"
}

variable "polygon_api_key" {
  type      = string
  sensitive = true
}

variable "polygon_plan" {
  type    = string
  default = "free"
}

variable "shared_app_insights" {
  type    = bool
  default = true
}

variable "langfuse_public_key" {
  type    = string
  default = ""
}
variable "langfuse_secret_key" {
  type      = string
  default   = ""
  sensitive = true
}
variable "langfuse_host" {
  type    = string
  default = "https://us.cloud.langfuse.com"
}

variable "openai_api_key" {
  description = "Optional: enables OpenAI Agents SDK tracing"
  type        = string
  default     = ""
  sensitive   = true
}
