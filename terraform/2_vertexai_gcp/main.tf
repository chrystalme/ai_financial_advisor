terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.40"
    }
  }
   backend "gcs" {
    bucket = "alex-ai-prod-alex-tfstate"
    prefix = "2_vertexai"   # unique per directory
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# Vertex AI is a managed API — no endpoint to deploy for embeddings.
# This guide just ensures the API is enabled. Safe to re-apply.
resource "google_project_service" "aiplatform" {
  project            = var.project_id
  service            = "aiplatform.googleapis.com"
  disable_on_destroy = false
}
