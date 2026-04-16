terraform {
  required_providers {
    google  = { source = "hashicorp/google", version = "~> 5.40" }
    archive = { source = "hashicorp/archive", version = "~> 2.4" }
  }
   backend "gcs" {
    bucket = "alex-ai-prod-alex-tfstate"
    prefix = "6_agents"   # unique per directory
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  prefix = "alex"
}

# --- Source bucket for function zips --------------------------------------
resource "google_storage_bucket" "functions" {
  name                        = "${var.project_id}-${local.prefix}-agent-functions"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true
}

# --- Pub/Sub topic + DLQ --------------------------------------------------
resource "google_pubsub_topic" "jobs" {
  name = "${local.prefix}-agent-jobs"
}

resource "google_pubsub_topic" "dlq" {
  name = "${local.prefix}-agent-dlq"
}

# --- Per-agent source archives --------------------------------------------
# Each agent imports `from src import Database` — the database package lives
# at backend/database/src/.  Cloud Functions only sees the zip, so we merge
# each agent dir + the shared database src/ into a staging directory and zip
# that.  A null_resource copies the files; archive_file zips the result.

resource "null_resource" "agent_stage" {
  for_each = toset(var.agents)

  triggers = {
    agent_hash = sha1(join("", [
      for f in fileset("${path.module}/../../backend/${each.key}", "**") :
      filesha1("${path.module}/../../backend/${each.key}/${f}")
    ]))
    db_hash = sha1(join("", [
      for f in fileset("${path.module}/../../backend/database/src", "**") :
      filesha1("${path.module}/../../backend/database/src/${f}")
    ]))
  }

  provisioner "local-exec" {
    command = <<-EOT
      rm -rf ${path.module}/.stage/${each.key}
      mkdir -p ${path.module}/.stage/${each.key}
      cp -r ${path.module}/../../backend/${each.key}/. ${path.module}/.stage/${each.key}/
      cp -r ${path.module}/../../backend/database/src ${path.module}/.stage/${each.key}/src
      cd ${path.module}/.stage/${each.key}
      sed -i '' '/alex-database/d' pyproject.toml
      sed -i '' 's/"functions-framework>=3.0.0",/"cloud-sql-python-connector[pg8000]>=1.0.0",\n    "functions-framework>=3.0.0",\n    "google-cloud-secret-manager>=2.20.0",\n    "psycopg>=3.1.0",/' pyproject.toml
      rm -f uv.lock
    EOT
  }
}

data "archive_file" "agent" {
  for_each    = toset(var.agents)
  type        = "zip"
  source_dir  = "${path.module}/.stage/${each.key}"
  output_path = "${path.module}/.build/${each.key}.zip"
  depends_on  = [null_resource.agent_stage]
}

resource "google_storage_bucket_object" "agent_src" {
  for_each = toset(var.agents)
  name     = "${each.key}-${data.archive_file.agent[each.key].output_sha}.zip"
  bucket   = google_storage_bucket.functions.name
  source   = data.archive_file.agent[each.key].output_path
}

# --- Per-agent service accounts -------------------------------------------
resource "google_service_account" "agent" {
  for_each     = toset(var.agents)
  account_id   = "${local.prefix}-${each.key}-sa"
  display_name = "Alex ${each.key} agent"
}

resource "google_project_iam_member" "agent_aiplatform" {
  for_each = toset(var.agents)
  project  = var.project_id
  role     = "roles/aiplatform.user"
  member   = "serviceAccount:${google_service_account.agent[each.key].email}"
}

resource "google_project_iam_member" "agent_sql" {
  for_each = toset(var.agents)
  project  = var.project_id
  role     = "roles/cloudsql.client"
  member   = "serviceAccount:${google_service_account.agent[each.key].email}"
}

resource "google_project_iam_member" "agent_secrets" {
  for_each = toset(var.agents)
  project  = var.project_id
  role     = "roles/secretmanager.secretAccessor"
  member   = "serviceAccount:${google_service_account.agent[each.key].email}"
}

resource "google_project_iam_member" "agent_pubsub" {
  for_each = toset(var.agents)
  project  = var.project_id
  role     = "roles/pubsub.publisher"
  member   = "serviceAccount:${google_service_account.agent[each.key].email}"
}

# --- Cloud Run functions --------------------------------------------------
resource "google_cloudfunctions2_function" "agent" {
  for_each = toset(var.agents)
  name     = "${local.prefix}-${each.key}"
  location = var.region

  build_config {
    runtime     = "python312"
    entry_point = "handler"
    environment_variables = {
      GOOGLE_FUNCTION_SOURCE = "main_gcp.py"
    }
    source {
      storage_source {
        bucket = google_storage_bucket.functions.name
        object = google_storage_bucket_object.agent_src[each.key].name
      }
    }
  }

  service_config {
    max_instance_count    = 20
    available_memory      = "1024Mi"
    timeout_seconds       = 540
    service_account_email = google_service_account.agent[each.key].email

    environment_variables = {
      CLOUD_PROVIDER           = "gcp"
      VERTEX_PROJECT           = var.project_id
      VERTEX_LOCATION          = var.region
      MODEL_ID                 = var.vertex_model_id
      CLOUDSQL_CONNECTION_NAME = var.cloudsql_connection_name
      DB_SECRET_NAME           = var.db_secret_name
      VECTOR_INDEX_ENDPOINT_ID = var.vector_index_endpoint_id
      DEPLOYED_INDEX_ID        = var.deployed_index_id
      POLYGON_API_KEY          = var.polygon_api_key
      POLYGON_PLAN             = var.polygon_plan
      PUBSUB_TOPIC             = google_pubsub_topic.jobs.name
      LANGFUSE_PUBLIC_KEY      = var.langfuse_public_key
      LANGFUSE_SECRET_KEY      = var.langfuse_secret_key
      LANGFUSE_HOST            = var.langfuse_host
      OPENAI_API_KEY           = var.openai_api_key
    }
  }
}

# --- Pub/Sub triggers the planner ----------------------------------------
resource "google_pubsub_subscription" "planner" {
  name  = "${local.prefix}-planner-sub"
  topic = google_pubsub_topic.jobs.name

  ack_deadline_seconds = 600

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dlq.id
    max_delivery_attempts = 5
  }

  push_config {
    push_endpoint = google_cloudfunctions2_function.agent["planner"].service_config[0].uri
    oidc_token {
      service_account_email = google_service_account.agent["planner"].email
    }
  }
}
