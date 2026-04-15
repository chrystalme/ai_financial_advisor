output "connection_name" {
  description = "project:region:instance — used with Cloud SQL Auth Proxy"
  value       = google_sql_database_instance.alex.connection_name
}

output "instance_name" {
  value = google_sql_database_instance.alex.name
}

output "public_ip" {
  value = google_sql_database_instance.alex.public_ip_address
}

output "db_secret_name" {
  value = google_secret_manager_secret.db.secret_id
}

output "database" {
  value = google_sql_database.alex.name
}

output "db_user" {
  value = google_sql_user.alex.name
}
