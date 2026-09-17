resource "helm_release" "aws_load_balancer_controller" {
  name             = "aws-load-balancer-controller"
  namespace        = "kube-system"
  create_namespace = false
  repository       = "https://aws.github.io/eks-charts"
  chart            = "aws-load-balancer-controller"
  version          = "1.12.0"
  atomic           = true
  cleanup_on_fail  = true
  wait             = true
  timeout          = 600
  values = [yamlencode({
    clusterName = var.cluster_name
    region      = var.aws_region
    vpcId       = var.vpc_id
    serviceAccount = {
      create = true
      name   = "aws-load-balancer-controller"
      annotations = {
        "eks.amazonaws.com/role-arn" = var.load_balancer_controller_role_arn
      }
    }
    resources = {
      requests = { cpu = "100m", memory = "128Mi" }
      limits   = { cpu = "250m", memory = "256Mi" }
    }
  })]
}

resource "helm_release" "metrics_server" {
  name             = "metrics-server"
  namespace        = "kube-system"
  create_namespace = false
  repository       = "https://kubernetes-sigs.github.io/metrics-server/"
  chart            = "metrics-server"
  version          = "3.12.2"
  atomic           = true
  cleanup_on_fail  = true
  wait             = true
  timeout          = 600
  values = [yamlencode({
    resources = {
      requests = { cpu = "50m", memory = "64Mi" }
      limits   = { cpu = "100m", memory = "128Mi" }
    }
  })]
}

resource "helm_release" "secrets_store_csi_driver" {
  name             = "secrets-store-csi-driver"
  namespace        = "kube-system"
  create_namespace = false
  repository       = "https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts"
  chart            = "secrets-store-csi-driver"
  version          = "1.4.8"
  atomic           = true
  cleanup_on_fail  = true
  wait             = true
  timeout          = 600
  values = [yamlencode({
    syncSecret           = { enabled = true }
    enableSecretRotation = false
    linux = {
      resources = {
        requests = { cpu = "50m", memory = "64Mi" }
        limits   = { cpu = "100m", memory = "128Mi" }
      }
    }
  })]
}

resource "helm_release" "secrets_store_csi_aws_provider" {
  name             = "secrets-store-csi-driver-provider-aws"
  namespace        = "kube-system"
  create_namespace = false
  repository       = "https://aws.github.io/secrets-store-csi-driver-provider-aws"
  chart            = "secrets-store-csi-driver-provider-aws"
  version          = "0.3.9"
  atomic           = true
  cleanup_on_fail  = true
  wait             = true
  timeout          = 600
  values = [yamlencode({
    resources = {
      requests = { cpu = "50m", memory = "64Mi" }
      limits   = { cpu = "100m", memory = "128Mi" }
    }
  })]
  depends_on = [helm_release.secrets_store_csi_driver]
}
