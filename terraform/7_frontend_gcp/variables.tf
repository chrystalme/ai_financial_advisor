variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "frontend_host" {
  description = "gcs = serve from Cloud Storage + Cloud CDN; external = you host the frontend on Vercel/etc."
  type        = string
  default     = "external"
  validation {
    condition     = contains(["gcs", "external"], var.frontend_host)
    error_message = "frontend_host must be 'gcs' or 'external'"
  }
}

variable "frontend_domain" {
  description = "Required when frontend_host=gcs. Must be a domain you control."
  type        = string
  default     = ""
}

variable "clerk_jwks_url" {
  type = string
}

variable "clerk_issuer" {
  type    = string
  default = ""
}

variable "api_container_image" {
  description = "Cloud Run API image (leave blank to deploy a placeholder first)"
  type        = string
  default     = ""
}

variable "cloudsql_connection_name" {
  type = string
}

variable "db_secret_name" {
  type    = string
  default = "alex-db-credentials"
}

variable "jobs_topic" {
  description = "Pub/Sub topic the API publishes to (from guide 6)"
  type        = string
}

variable "cors_origins" {
  description = "Comma-separated allowed CORS origins"
  type        = string
  default     = "http://localhost:3000"
}
