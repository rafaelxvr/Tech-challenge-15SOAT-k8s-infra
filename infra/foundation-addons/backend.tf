terraform {
  # The private executor supplies this exact isolated key:
  # foundation-addons/terraform.tfstate (and its native S3 lockfile).
  backend "s3" { use_lockfile = true }
}
