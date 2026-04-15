variable "subscription_id" {
  type = string
}

variable "resource_group" {
  type    = string
  default = "alex-rg"
}

variable "location" {
  type    = string
  default = "eastus"
}

variable "openai_name" {
  description = "Globally-unique Cognitive Services account name"
  type        = string
  default     = ""
}

variable "chat_deployment_name" {
  type    = string
  default = "gpt-4o"
}

variable "chat_model_name" {
  type    = string
  default = "gpt-4o"
}

variable "chat_model_version" {
  type    = string
  default = "2024-08-06"
}

variable "chat_sku_name" {
  type    = string
  default = "GlobalStandard"
}

variable "chat_sku_capacity" {
  type    = number
  default = 50
}

variable "embedding_deployment_name" {
  type    = string
  default = "text-embedding-3-small"
}

variable "embedding_model_version" {
  type    = string
  default = "1"
}

variable "embedding_sku_capacity" {
  type    = number
  default = 120
}
