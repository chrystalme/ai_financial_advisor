variable "subscription_id" { type = string }
variable "resource_group" {
  type    = string
  default = "alex-rg"
}
variable "location" {
  type    = string
  default = "eastus"
}

variable "search_sku" {
  description = "free, basic, standard"
  type        = string
  default     = "free"
}

variable "embedding_dimensions" {
  type    = number
  default = 1536
}

variable "azure_openai_endpoint" {
  type = string
}

variable "azure_openai_key" {
  type      = string
  sensitive = true
}

variable "azure_openai_embedding_deployment" {
  type    = string
  default = "text-embedding-3-small"
}
