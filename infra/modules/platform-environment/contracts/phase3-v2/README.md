# Phase 3 v2 gateway route contract

This is the immutable APP-owned Phase 3 v2 `routes.json` snapshot consumed by
the platform Terraform module. Its SHA-256 is
`7e1cff5e6c57174af792bb44b33e63572f885698ab5ef2f24d5aeebda883c1a8`.

The module creates routes only for `ALLOW` entries. The retired email mutation
is therefore absent, and the v2 ADMIN report route is protected by the Lambda
REQUEST authorizer.
