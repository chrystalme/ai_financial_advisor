terraform {
  required_providers {
    google = { source = "hashicorp/google", version = "~> 5.40" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

resource "random_password" "db" {
  length  = 32
  special = false
}

locals {
  password = var.db_password != "" ? var.db_password : random_password.db.result
}

resource "google_sql_database_instance" "alex" {
  name             = "alex-db"
  region           = var.region
  database_version = "POSTGRES_16"

  deletion_protection = var.deletion_protection

  settings {
    tier              = var.db_tier
    activation_policy = var.activation_policy
    availability_type = "ZONAL"
    disk_size         = 10
    disk_autoresize   = true

    ip_configuration {
      ipv4_enabled = true
      # No authorized_networks — use Cloud SQL Auth Proxy for all connections.
    }

    backup_configuration {
      enabled    = true
      start_time = "03:00"
    }
  }
}

resource "google_sql_database" "alex" {
  name     = var.db_name
  instance = google_sql_database_instance.alex.name
}

resource "google_sql_user" "alex" {
  name     = var.db_user
  instance = google_sql_database_instance.alex.name
  password = local.password
}

resource "google_secret_manager_secret" "db" {
  secret_id = "alex-db-credentials"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "db" {
  secret = google_secret_manager_secret.db.id
  secret_data = jsonencode({
    username         = var.db_user
    password         = local.password
    database         = var.db_name
    connection_name  = google_sql_database_instance.alex.connection_name
    public_ip        = google_sql_database_instance.alex.public_ip_address
  })
}
