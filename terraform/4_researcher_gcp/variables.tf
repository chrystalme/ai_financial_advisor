variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "vertex_model_id" {
  description = "LiteLLM-style Vertex model id (e.g. vertex_ai/gemini-2.5-pro)"
  type        = string
  default     = "vertex_ai/gemini-2.5-pro"
}

variable "alex_api_endpoint" {
  description = "Ingest API endpoint from guide 3"
  type        = string
}

variable "alex_api_key" {
  description = "Ingest API key from guide 3"
  type        = string
  sensitive   = true
}

variable "scheduler_enabled" {
  type    = bool
  default = false
}

variable "schedule_cron" {
  type    = string
  default = "0 */6 * * *"
}

variable "openai_api_key" {
  description = "OpenAI API key for Agents SDK trace export"
  type        = string
  sensitive   = true
  default     = ""
}

variable "container_image" {
  description = "Fully-qualified Artifact Registry image for the researcher; leave empty to use a placeholder until first push"
  type        = string
  default     = ""
}
