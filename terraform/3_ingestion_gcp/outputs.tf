output "ingest_function_url" {
  value = google_cloudfunctions2_function.ingest.service_config[0].uri
}

output "vector_index_id" {
  value = google_vertex_ai_index.docs.id
}

output "vector_index_endpoint_id" {
  value = google_vertex_ai_index_endpoint.docs.id
}

output "deployed_index_id" {
  value = var.deployed_index_id
}

output "docs_bucket" {
  value = google_storage_bucket.docs.name
}

output "api_key" {
  value     = google_secret_manager_secret_version.api_key.secret_data
  sensitive = true
}
