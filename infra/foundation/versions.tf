terraform {
  required_version = "= 1.15.8"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 5.100.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "= 2.17.0"
    }
  }
}
