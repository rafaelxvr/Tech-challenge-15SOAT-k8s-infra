mock_provider "helm" {}

variables {
  aws_region                        = "us-east-1"
  cluster_name                      = "oficina-phase3"
  cluster_endpoint                  = "https://private.eks.example"
  cluster_ca_certificate            = "Y2E="
  vpc_id                            = "vpc-12345678"
  load_balancer_controller_role_arn = "arn:aws:iam::123456789012:role/oficina-phase3-aws-load-balancer-controller"
}

run "only_pinned_foundation_addons" {
  command = plan
  assert {
    condition     = helm_release.aws_load_balancer_controller.version == "1.12.0" && helm_release.metrics_server.version == "3.12.2" && helm_release.secrets_store_csi_driver.version == "1.4.8" && helm_release.secrets_store_csi_aws_provider.version == "0.3.9"
    error_message = "The isolated root must contain only the four reviewed, pinned foundation addons."
  }
}
