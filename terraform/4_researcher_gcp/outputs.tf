output "researcher_url" {
  value = google_cloud_run_v2_service.researcher.uri
}

output "artifact_registry_repo" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.alex.repository_id}"
}

output "service_account_email" {
  value = google_service_account.researcher.email
}
