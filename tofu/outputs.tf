output "postgres_service_host" {
  description = "In-cluster hostname for the Postgres backend store."
  value       = "postgres.${var.namespace}"
}

output "mlflow_tracking_uri" {
  description = "In-cluster MLflow tracking URI (pass to pipeline parameters)."
  value       = "http://mlflow.${var.namespace}:5000"
}
