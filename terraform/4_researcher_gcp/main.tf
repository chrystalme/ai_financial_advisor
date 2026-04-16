terraform {
  required_providers {
    google = { source = "hashicorp/google", version = "~> 5.40" }
    null   = { source = "hashicorp/null", version = "~> 3.2" }
  }
   backend "gcs" {
    bucket = "alex-ai-prod-alex-tfstate"
    prefix = "4_researcher"   # unique per directory
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  name     = "alex-researcher"
  ar_repo  = "alex"
  image    = var.container_image != "" ? var.container_image : "${var.region}-docker.pkg.dev/${var.project_id}/${local.ar_repo}/researcher:latest"
}

resource "google_artifact_registry_repository" "alex" {
  location      = var.region
  repository_id = local.ar_repo
  format        = "DOCKER"
}

resource "null_resource" "build_push" {
  triggers = {
    src_hash = sha1(join("", [
      for f in fileset("${path.module}/../../backend/researcher", "**") :
      filesha1("${path.module}/../../backend/researcher/${f}")
    ]))
  }

  provisioner "local-exec" {
    command = <<-EOT
      gcloud auth configure-docker ${var.region}-docker.pkg.dev --quiet
      docker build --platform linux/amd64 -t ${local.image} ${path.module}/../../backend/researcher
      docker push ${local.image}
    EOT
  }

  depends_on = [google_artifact_registry_repository.alex]
}

resource "google_service_account" "researcher" {
  account_id   = "${local.name}-sa"
  display_name = "Alex researcher"
}

resource "google_project_iam_member" "researcher_aiplatform" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.researcher.email}"
}

resource "google_project_iam_member" "researcher_secrets" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.researcher.email}"
}

resource "google_cloud_run_v2_service" "researcher" {
  name     = local.name
  location = var.region

  template {
    service_account = google_service_account.researcher.email
    timeout         = "3600s"
    scaling {
      min_instance_count = 0
      max_instance_count = 3
    }
    containers {
      image = local.image
      ports {
        container_port = 8000
      }
      resources {
        limits = { cpu = "2", memory = "4Gi" }
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
        name  = "VERTEX_LOCATION"
        value = var.region
      }
      env {
        name  = "MODEL_ID"
        value = var.vertex_model_id
      }
      env {
        name  = "ALEX_API_ENDPOINT"
        value = var.alex_api_endpoint
      }
      env {
        name  = "ALEX_API_KEY"
        value = var.alex_api_key
      }
      env {
        name  = "OPENAI_API_KEY"
        value = var.openai_api_key
      }
      env {
        name  = "SERPER_API_KEY"
        value = var.serper_api_key
      }
    }
  }

  lifecycle {
    ignore_changes = []
  }

  depends_on = [null_resource.build_push]
}

resource "google_cloud_run_v2_service_iam_member" "public" {
  project  = var.project_id
  location = google_cloud_run_v2_service.researcher.location
  name     = google_cloud_run_v2_service.researcher.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# --- Optional scheduler ---------------------------------------------------
resource "google_service_account" "scheduler" {
  count        = var.scheduler_enabled ? 1 : 0
  account_id   = "${local.name}-scheduler"
  display_name = "Alex researcher scheduler"
}

resource "google_cloud_run_v2_service_iam_member" "scheduler_invoke" {
  count    = var.scheduler_enabled ? 1 : 0
  project  = var.project_id
  location = google_cloud_run_v2_service.researcher.location
  name     = google_cloud_run_v2_service.researcher.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.scheduler[0].email}"
}

resource "google_cloud_scheduler_job" "research" {
  count     = var.scheduler_enabled ? 1 : 0
  name      = "${local.name}-schedule"
  schedule  = var.schedule_cron
  region    = var.region
  time_zone = "UTC"

  http_target {
    http_method = "GET"
    uri         = "${google_cloud_run_v2_service.researcher.uri}/research/auto"
    oidc_token {
      service_account_email = google_service_account.scheduler[0].email
    }
  }
}
