terraform {
  required_version = "= 1.15.8"
  required_providers {
    helm     = { source = "hashicorp/helm", version = "= 2.17.0" }
    newrelic = { source = "newrelic/newrelic", version = "= 3.57.0" }
  }
}
