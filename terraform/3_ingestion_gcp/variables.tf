variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "embedding_dimensions" {
  description = "Must match the embedding model (768 for text-embedding-005)"
  type        = number
  default     = 768
}

variable "deployed_index_id" {
  type    = string
  default = "alex_docs_v1"
}

variable "index_deployed" {
  description = "Set false to undeploy the index endpoint for cost savings without losing the index"
  type        = bool
  default     = true
}

variable "api_key_value" {
  description = "API key value for the ingest API Gateway (if empty, one is generated)"
  type        = string
  default     = ""
  sensitive   = true
}
