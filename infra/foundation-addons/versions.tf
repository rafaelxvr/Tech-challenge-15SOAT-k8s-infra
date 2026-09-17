terraform {
  required_version = "= 1.15.8"
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "= 2.17.0"
    }
  }
}
