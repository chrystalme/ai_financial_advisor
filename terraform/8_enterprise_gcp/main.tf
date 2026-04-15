terraform {
  required_providers {
    google = { source = "hashicorp/google", version = "~> 5.40" }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# --- Notification channel -------------------------------------------------
resource "google_monitoring_notification_channel" "email" {
  display_name = "Alex alerts"
  type         = "email"
  labels = {
    email_address = var.notification_email
  }
}

# --- Alert: Cloud Run 5xx error rate -------------------------------------
resource "google_monitoring_alert_policy" "cloud_run_errors" {
  display_name = "Alex Cloud Run 5xx > 1%"
  combiner     = "OR"

  conditions {
    display_name = "5xx rate elevated"
    condition_threshold {
      filter          = "metric.type=\"run.googleapis.com/request_count\" AND resource.type=\"cloud_run_revision\" AND metric.label.\"response_code_class\"=\"5xx\""
      comparison      = "COMPARISON_GT"
      duration        = "300s"
      threshold_value = 5
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_RATE"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]
}

# --- Alert: Pub/Sub oldest unacked message age ---------------------------
resource "google_monitoring_alert_policy" "pubsub_backlog" {
  display_name = "Alex Pub/Sub backlog > 5 min"
  combiner     = "OR"

  conditions {
    display_name = "oldest unacked age"
    condition_threshold {
      filter          = "metric.type=\"pubsub.googleapis.com/subscription/oldest_unacked_message_age\" AND resource.type=\"pubsub_subscription\""
      comparison      = "COMPARISON_GT"
      duration        = "300s"
      threshold_value = 300
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MAX"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]
}

# --- Alert: Cloud SQL CPU -------------------------------------------------
resource "google_monitoring_alert_policy" "sql_cpu" {
  display_name = "Alex Cloud SQL CPU > 80%"
  combiner     = "OR"

  conditions {
    display_name = "cpu high"
    condition_threshold {
      filter          = "metric.type=\"cloudsql.googleapis.com/database/cpu/utilization\" AND resource.type=\"cloudsql_database\""
      comparison      = "COMPARISON_GT"
      duration        = "600s"
      threshold_value = 0.8
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]
}

# --- Uptime check on the API --------------------------------------------
resource "google_monitoring_uptime_check_config" "api_health" {
  display_name = "alex-api health"
  timeout      = "10s"
  period       = "60s"

  http_check {
    path         = "/health"
    port         = 443
    use_ssl      = true
    validate_ssl = true
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      host = "${var.api_service_name}-${var.project_id}.${var.region}.run.app"
    }
  }
}

# --- Log-based metric for agent task latency ------------------------------
resource "google_logging_metric" "agent_latency" {
  name   = "alex/agent_task_latency_ms"
  filter = "resource.type=\"cloud_run_revision\" AND jsonPayload.event=\"agent_task_completed\""

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "DISTRIBUTION"
    unit        = "ms"
    labels {
      key        = "agent"
      value_type = "STRING"
    }
  }

  label_extractors = {
    "agent" = "EXTRACT(jsonPayload.agent)"
  }

  value_extractor = "EXTRACT(jsonPayload.duration_ms)"

  bucket_options {
    exponential_buckets {
      num_finite_buckets = 32
      growth_factor      = 2
      scale              = 10
    }
  }
}

# --- Dashboard ------------------------------------------------------------
resource "google_monitoring_dashboard" "overview" {
  dashboard_json = jsonencode({
    displayName = "Alex Overview"
    mosaicLayout = {
      columns = 12
      tiles = [
        {
          width = 6, height = 4
          widget = {
            title = "Cloud Run request rate"
            xyChart = {
              dataSets = [{
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter             = "metric.type=\"run.googleapis.com/request_count\" AND resource.type=\"cloud_run_revision\""
                    aggregation        = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_RATE", crossSeriesReducer = "REDUCE_SUM", groupByFields = ["resource.label.service_name"] }
                  }
                }
              }]
            }
          }
        },
        {
          xPos = 6, width = 6, height = 4
          widget = {
            title = "Cloud Run p95 latency"
            xyChart = {
              dataSets = [{
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter      = "metric.type=\"run.googleapis.com/request_latencies\" AND resource.type=\"cloud_run_revision\""
                    aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_PERCENTILE_95", crossSeriesReducer = "REDUCE_MEAN", groupByFields = ["resource.label.service_name"] }
                  }
                }
              }]
            }
          }
        },
        {
          yPos = 4, width = 6, height = 4
          widget = {
            title = "Vertex AI prediction count"
            xyChart = {
              dataSets = [{
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter      = "metric.type=\"aiplatform.googleapis.com/publisher/online_serving/request_count\""
                    aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_RATE", crossSeriesReducer = "REDUCE_SUM" }
                  }
                }
              }]
            }
          }
        },
        {
          xPos = 6, yPos = 4, width = 6, height = 4
          widget = {
            title = "Cloud SQL CPU"
            xyChart = {
              dataSets = [{
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter      = "metric.type=\"cloudsql.googleapis.com/database/cpu/utilization\" AND resource.type=\"cloudsql_database\""
                    aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_MEAN" }
                  }
                }
              }]
            }
          }
        },
        {
          yPos = 8, width = 12, height = 4
          widget = {
            title = "Pub/Sub unacked message age"
            xyChart = {
              dataSets = [{
                timeSeriesQuery = {
                  timeSeriesFilter = {
                    filter      = "metric.type=\"pubsub.googleapis.com/subscription/oldest_unacked_message_age\""
                    aggregation = { alignmentPeriod = "60s", perSeriesAligner = "ALIGN_MAX", crossSeriesReducer = "REDUCE_MAX", groupByFields = ["resource.label.subscription_id"] }
                  }
                }
              }]
            }
          }
        }
      ]
    }
  })
}
