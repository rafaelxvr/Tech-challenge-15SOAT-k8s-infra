terraform {
  # Supplied through reviewed backend configuration after I1 bootstrap migration.
  backend "s3" { use_lockfile = true }
}
