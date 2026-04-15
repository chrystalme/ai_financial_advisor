output "agent_urls" {
  value = { for k, f in google_cloudfunctions2_function.agent : k => f.service_config[0].uri }
}

output "jobs_topic" {
  value = google_pubsub_topic.jobs.name
}

output "dlq_topic" {
  value = google_pubsub_topic.dlq.name
}

output "functions_bucket" {
  value = google_storage_bucket.functions.name
}
