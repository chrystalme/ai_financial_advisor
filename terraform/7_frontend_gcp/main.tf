terraform {
  required_providers {
    google = { source = "hashicorp/google", version = "~> 5.40" }
    null   = { source = "hashicorp/null", version = "~> 3.2" }
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

# --- Build and push API container ------------------------------------------
resource "null_resource" "api_build_push" {
  triggers = {
    api_hash = sha1(join("", [
      for f in fileset("${path.module}/../../backend/api", "**") :
      filesha1("${path.module}/../../backend/api/${f}")
    ]))
    db_hash = sha1(join("", [
      for f in fileset("${path.module}/../../backend/database/src", "**") :
      filesha1("${path.module}/../../backend/database/src/${f}")
    ]))
  }

  provisioner "local-exec" {
    command = <<-EOT
      # Stage: combine api + database src, strip local path dep
      rm -rf ${path.module}/.stage/api
      mkdir -p ${path.module}/.stage/api
      cp -r ${path.module}/../../backend/api/. ${path.module}/.stage/api/
      cp -r ${path.module}/../../backend/database/src ${path.module}/.stage/api/src
      cd ${path.module}/.stage/api
      sed -i '' '/alex-database/d' pyproject.toml
      sed -i '' '/tool.uv.sources/d' pyproject.toml
      sed -i '' '/workspace/d' pyproject.toml
      # Add GCP deps
      sed -i '' 's/"fastapi>/"cloud-sql-python-connector[pg8000]>=1.0.0",\n    "google-cloud-pubsub>=2.0.0",\n    "google-cloud-secret-manager>=2.20.0",\n    "psycopg[binary]>=3.1.0",\n    "fastapi>/' pyproject.toml
      rm -f uv.lock
      # Build and push
      gcloud auth configure-docker ${var.region}-docker.pkg.dev --quiet
      docker build --platform linux/amd64 -t ${local.image} .
      docker push ${local.image}
    EOT
  }
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
      ports {
        container_port = 8080
      }
      resources {
        limits = { cpu = "1", memory = "1Gi" }
      }
      env {
        name  = "CLOUD_PROVIDER"
        value = "gcp"
      }
      env {
        name  = "VERTEX_PROJECT"
        value = var.project_id
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

  depends_on = [null_resource.api_build_push]
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

# HTTP proxy + forwarding rule (works without a domain/SSL cert)
resource "google_compute_target_http_proxy" "frontend" {
  count   = var.frontend_host == "gcs" ? 1 : 0
  name    = "${local.prefix}-frontend-http-proxy"
  url_map = google_compute_url_map.frontend[0].id
}

resource "google_compute_global_forwarding_rule" "frontend_http" {
  count                 = var.frontend_host == "gcs" ? 1 : 0
  name                  = "${local.prefix}-frontend-http-fr"
  target                = google_compute_target_http_proxy.frontend[0].id
  port_range            = "80"
  ip_address            = google_compute_global_address.frontend[0].address
  load_balancing_scheme = "EXTERNAL_MANAGED"
}
