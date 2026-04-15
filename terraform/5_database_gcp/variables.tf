variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "db_tier" {
  description = "Cloud SQL machine tier"
  type        = string
  default     = "db-custom-1-3840"
}

variable "db_name" {
  type    = string
  default = "alex"
}

variable "db_user" {
  type    = string
  default = "alex_app"
}

variable "db_password" {
  description = "Leave empty to auto-generate"
  type        = string
  default     = ""
  sensitive   = true
}

variable "deletion_protection" {
  type    = bool
  default = false
}

variable "activation_policy" {
  description = "ALWAYS or NEVER — set NEVER to stop the instance between sessions"
  type        = string
  default     = "ALWAYS"
}
