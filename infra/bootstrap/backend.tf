terraform {
  # Configure only after the local bootstrap state has been migrated. See docs/bootstrap.md.
  backend "s3" {
    use_lockfile = true
  }
}
