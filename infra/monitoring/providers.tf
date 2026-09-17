provider "helm" {
  kubernetes {
    host                   = var.cluster_endpoint
    cluster_ca_certificate = base64decode(var.cluster_ca_certificate)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--region", "us-east-1", "--cluster-name", var.cluster_name]
    }
  }
}

# The private executor maps its protected NEW_RELIC_API_KEY to TF_VAR_newrelic_api_key.
# It is a sensitive provider-only input, never a chart value, Kubernetes Secret, or output.
provider "newrelic" {
  account_id = var.newrelic_account_id
  api_key    = var.newrelic_api_key
}
