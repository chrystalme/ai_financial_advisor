variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "notification_email" {
  description = "Email address to receive alerts"
  type        = string
}

variable "vertex_model_id" {
  type    = string
  default = "gemini-2.5-pro"
}

variable "api_service_name" {
  type    = string
  default = "alex-api"
}

variable "agent_service_names" {
  type    = list(string)
  default = ["alex-planner", "alex-tagger", "alex-reporter", "alex-charter", "alex-retirement"]
}
