output "api_url" {
  value = google_cloud_run_v2_service.api.uri
}

output "frontend_bucket" {
  value = var.frontend_host == "gcs" ? google_storage_bucket.frontend[0].name : null
}

output "frontend_lb_ip" {
  value = var.frontend_host == "gcs" ? google_compute_global_address.frontend[0].address : null
}
