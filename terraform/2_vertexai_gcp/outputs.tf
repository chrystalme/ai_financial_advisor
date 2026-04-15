output "embedding_model" {
  description = "Vertex AI embedding model name (fully managed, no endpoint ID needed)"
  value       = var.embedding_model
}

output "embedding_dimensions" {
  description = "Output dimension of the selected embedding model"
  value       = 768
}

output "region" {
  value = var.region
}
