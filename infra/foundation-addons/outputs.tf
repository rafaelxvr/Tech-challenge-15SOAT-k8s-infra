output "addon_releases" {
  value = {
    aws_load_balancer_controller   = helm_release.aws_load_balancer_controller.version
    metrics_server                 = helm_release.metrics_server.version
    secrets_store_csi_driver       = helm_release.secrets_store_csi_driver.version
    secrets_store_csi_aws_provider = helm_release.secrets_store_csi_aws_provider.version
  }
}
