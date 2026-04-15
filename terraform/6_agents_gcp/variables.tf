variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "vertex_model_id" {
  type    = string
  default = "vertex_ai/gemini-2.5-pro"
}

variable "cloudsql_connection_name" {
  description = "From guide 5"
  type        = string
}

variable "db_secret_name" {
  description = "Secret Manager secret holding DB credentials"
  type        = string
  default     = "alex-db-credentials"
}

variable "vector_index_endpoint_id" {
  description = "From guide 3"
  type        = string
}

variable "deployed_index_id" {
  type    = string
  default = "alex_docs_v1"
}

variable "polygon_api_key" {
  type      = string
  sensitive = true
}

variable "polygon_plan" {
  type    = string
  default = "free"
}

# Optional LangFuse
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

variable "agents" {
  description = "Agent names to deploy"
  type        = list(string)
  default     = ["planner", "tagger", "reporter", "charter", "retirement"]
}
