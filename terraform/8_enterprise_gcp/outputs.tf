output "dashboard_id" {
  value = google_monitoring_dashboard.overview.id
}

output "notification_channel_id" {
  value = google_monitoring_notification_channel.email.id
}
