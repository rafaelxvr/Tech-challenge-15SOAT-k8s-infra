resource "terraform_data" "retired" {
  lifecycle {
    precondition {
      condition     = var.aws_region == "__retired__"
      error_message = "Retired legacy K8S Functions root: deploy oficina-functions/infra/environments/production instead."
    }
  }
}
