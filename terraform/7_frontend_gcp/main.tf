terraform {
  required_providers {
    google = { source = "hashicorp/google", version = "~> 5.40" }
  }
   backend "gcs" {
    bucket = "alex-ai-prod-alex-tfstate"
    prefix = "7_frontend"   # unique per directory
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  prefix = "alex"
  image  = var.api_container_image != "" ? var.api_container_image : "${var.region}-docker.pkg.dev/${var.project_id}/alex/api:latest"
}

# --- API service account --------------------------------------------------
resource "google_service_account" "api" {
  account_id   = "${local.prefix}-api-sa"
  display_name = "Alex API"
}

resource "google_project_iam_member" "api_sql" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.api.email}"
}

resource "google_project_iam_member" "api_secrets" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.api.email}"
}

resource "google_project_iam_member" "api_pubsub" {
  project = var.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.api.email}"
}

# --- Cloud Run API -------------------------------------------------------
resource "google_cloud_run_v2_service" "api" {
  name     = "${local.prefix}-api"
  location = var.region

  template {
    service_account = google_service_account.api.email
    scaling {
      min_instance_count = 0
      max_instance_count = 10
    }
    containers {
      image = local.image
      resources {
        limits = { cpu = "1", memory = "1Gi" }
      }
      env {
        name  = "CLOUD_PROVIDER"
        value = "gcp"
      }
      env {
        name  = "CLERK_JWKS_URL"
        value = var.clerk_jwks_url
      }
      env {
        name  = "CLERK_ISSUER"
        value = var.clerk_issuer
      }
      env {
        name  = "CLOUDSQL_CONNECTION_NAME"
        value = var.cloudsql_connection_name
      }
      env {
        name  = "DB_SECRET_NAME"
        value = var.db_secret_name
      }
      env {
        name  = "PUBSUB_TOPIC"
        value = var.jobs_topic
      }
    }
    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [var.cloudsql_connection_name]
      }
    }
  }

  lifecycle {
    ignore_changes = [template[0].containers[0].image]
  }
}

resource "google_cloud_run_v2_service_iam_member" "api_public" {
  project  = var.project_id
  location = google_cloud_run_v2_service.api.location
  name     = google_cloud_run_v2_service.api.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# --- Optional: GCS + Cloud CDN for frontend -------------------------------
resource "google_storage_bucket" "frontend" {
  count                       = var.frontend_host == "gcs" ? 1 : 0
  name                        = "${var.project_id}-${local.prefix}-frontend"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true
  website {
    main_page_suffix = "index.html"
    not_found_page   = "404.html"
  }
}

resource "google_storage_bucket_iam_member" "frontend_public" {
  count  = var.frontend_host == "gcs" ? 1 : 0
  bucket = google_storage_bucket.frontend[0].name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

resource "google_compute_backend_bucket" "frontend" {
  count       = var.frontend_host == "gcs" ? 1 : 0
  name        = "${local.prefix}-frontend-backend"
  bucket_name = google_storage_bucket.frontend[0].name
  enable_cdn  = true
}

resource "google_compute_url_map" "frontend" {
  count           = var.frontend_host == "gcs" ? 1 : 0
  name            = "${local.prefix}-frontend-urlmap"
  default_service = google_compute_backend_bucket.frontend[0].id
}

resource "google_compute_managed_ssl_certificate" "frontend" {
  count = var.frontend_host == "gcs" && var.frontend_domain != "" ? 1 : 0
  name  = "${local.prefix}-frontend-cert"
  managed {
    domains = [var.frontend_domain]
  }
}

resource "google_compute_target_https_proxy" "frontend" {
  count            = var.frontend_host == "gcs" && var.frontend_domain != "" ? 1 : 0
  name             = "${local.prefix}-frontend-https-proxy"
  url_map          = google_compute_url_map.frontend[0].id
  ssl_certificates = [google_compute_managed_ssl_certificate.frontend[0].id]
}

resource "google_compute_global_address" "frontend" {
  count = var.frontend_host == "gcs" ? 1 : 0
  name  = "${local.prefix}-frontend-ip"
}

resource "google_compute_global_forwarding_rule" "frontend" {
  count                 = var.frontend_host == "gcs" && var.frontend_domain != "" ? 1 : 0
  name                  = "${local.prefix}-frontend-fr"
  target                = google_compute_target_https_proxy.frontend[0].id
  port_range            = "443"
  ip_address            = google_compute_global_address.frontend[0].address
  load_balancing_scheme = "EXTERNAL_MANAGED"
}
