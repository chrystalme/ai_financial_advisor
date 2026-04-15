terraform {
  required_providers {
    google = { source = "hashicorp/google", version = "~> 5.40" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
    archive = { source = "hashicorp/archive", version = "~> 2.4" }
  }
   backend "gcs" {
    bucket = "alex-ai-prod-alex-tfstate"
    prefix = "3_ingestion"   # unique per directory
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  name_prefix = "alex"
}

# --- Storage for documents and function source ----------------------------
resource "google_storage_bucket" "docs" {
  name                        = "${var.project_id}-${local.name_prefix}-docs"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true
}

resource "google_storage_bucket" "functions" {
  name                        = "${var.project_id}-${local.name_prefix}-functions"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true
}

# --- Vertex AI Matching Engine index --------------------------------------
resource "google_vertex_ai_index" "docs" {
  region       = var.region
  display_name = "${local.name_prefix}-docs-index"
  description  = "Alex document embeddings"
  metadata {
    contents_delta_uri = "gs://${google_storage_bucket.docs.name}/index-staging"
    config {
      dimensions                  = var.embedding_dimensions
      approximate_neighbors_count = 150
      distance_measure_type       = "COSINE_DISTANCE"
      feature_norm_type           = "UNIT_L2_NORM"
      shard_size                  = "SHARD_SIZE_SMALL"
      algorithm_config {
        tree_ah_config {
          leaf_node_embedding_count    = 500
          leaf_nodes_to_search_percent = 7
        }
      }
    }
  }
  index_update_method = "STREAM_UPDATE"
}

resource "google_vertex_ai_index_endpoint" "docs" {
  display_name            = "${local.name_prefix}-docs-endpoint"
  region                  = var.region
  public_endpoint_enabled = true
}

resource "google_vertex_ai_index_endpoint_deployed_index" "docs" {
  count             = var.index_deployed ? 1 : 0
  index_endpoint    = google_vertex_ai_index_endpoint.docs.id
  deployed_index_id = var.deployed_index_id
  display_name      = "${local.name_prefix}-docs-deployed"
  index             = google_vertex_ai_index.docs.id

  dedicated_resources {
    machine_spec {
      machine_type = "e2-standard-2"
    }
    min_replica_count = 1
    max_replica_count = 1
  }
}

# --- Cloud Run function for ingest ---------------------------------------
data "archive_file" "ingest_src" {
  type        = "zip"
  source_dir  = "${path.module}/../../backend/ingest"
  output_path = "${path.module}/.build/ingest.zip"
}

resource "google_storage_bucket_object" "ingest_src" {
  name   = "ingest-${data.archive_file.ingest_src.output_sha}.zip"
  bucket = google_storage_bucket.functions.name
  source = data.archive_file.ingest_src.output_path
}

resource "google_service_account" "ingest" {
  account_id   = "${local.name_prefix}-ingest-sa"
  display_name = "Alex ingest function"
}

resource "google_project_iam_member" "ingest_aiplatform" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.ingest.email}"
}

resource "google_project_iam_member" "ingest_storage" {
  project = var.project_id
  role    = "roles/storage.objectAdmin"
  member  = "serviceAccount:${google_service_account.ingest.email}"
}

resource "google_cloudfunctions2_function" "ingest" {
  name     = "${local.name_prefix}-ingest"
  location = var.region

  build_config {
    runtime     = "python311"
    entry_point = "handler"
    environment_variables = {
      GOOGLE_FUNCTION_SOURCE = "main_gcp.py"
    }
    source {
      storage_source {
        bucket = google_storage_bucket.functions.name
        object = google_storage_bucket_object.ingest_src.name
      }
    }
  }

  service_config {
    max_instance_count    = 10
    available_memory      = "512Mi"
    timeout_seconds       = 300
    service_account_email = google_service_account.ingest.email
    environment_variables = {
      GOOGLE_CLOUD_PROJECT     = var.project_id
      GOOGLE_CLOUD_REGION      = var.region
      VECTOR_INDEX_ID          = google_vertex_ai_index.docs.id
      VECTOR_INDEX_ENDPOINT_ID = google_vertex_ai_index_endpoint.docs.id
      DEPLOYED_INDEX_ID        = var.deployed_index_id
      DOCS_BUCKET              = google_storage_bucket.docs.name
      EMBEDDING_MODEL          = "text-embedding-005"
    }
  }
}

resource "google_cloud_run_service_iam_member" "ingest_invoker" {
  location = google_cloudfunctions2_function.ingest.location
  project  = var.project_id
  service  = google_cloudfunctions2_function.ingest.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# --- API key ---------------------------------------------------------------
resource "random_password" "api_key" {
  length  = 40
  special = false
}

resource "google_secret_manager_secret" "api_key" {
  secret_id = "${local.name_prefix}-ingest-api-key"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "api_key" {
  secret      = google_secret_manager_secret.api_key.id
  secret_data = var.api_key_value != "" ? var.api_key_value : random_password.api_key.result
}
