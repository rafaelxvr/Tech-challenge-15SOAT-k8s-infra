locals {
  github_oidc_host = "token.actions.githubusercontent.com"
  launcher_subjects = {
    for name, launcher in var.launchers : name => "repo:${launcher.repository}:environment:${launcher.environment}"
  }
  launcher_role_arns = toset([for role in aws_iam_role.launcher : role.arn])
  launcher_trust_policies = {
    for name, launcher in var.launchers : name => jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Sid       = "GitHubEnvironmentOnly"
        Effect    = "Allow"
        Action    = "sts:AssumeRoleWithWebIdentity"
        Principal = { Federated = var.github_oidc_provider_arn }
        Condition = {
          StringEquals = {
            "${local.github_oidc_host}:aud" = "sts.amazonaws.com"
            "${local.github_oidc_host}:sub" = local.launcher_subjects[name]
          }
        }
      }]
    })
  }
  launcher_permission_policies = {
    for name, launcher in var.launchers : name => jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Sid      = "UploadOnlyReviewedSourcePrefix"
          Effect   = "Allow"
          Action   = "s3:PutObject"
          Resource = "${aws_s3_bucket.artifact.arn}/${launcher.source_prefix}/*"
        },
        {
          Sid      = "StartOnlyItsDeploymentProject"
          Effect   = "Allow"
          Action   = ["codebuild:StartBuild", "codebuild:BatchGetBuilds"]
          Resource = launcher.codebuild_project_arn
        }
      ]
    })
  }
  state_access_policies = {
    for name, key in var.state_keys : name => jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Sid       = "ListOnlyItsStatePrefix"
          Effect    = "Allow"
          Action    = "s3:ListBucket"
          Resource  = aws_s3_bucket.state.arn
          Condition = { StringLike = { "s3:prefix" = [key, "${key}.tflock"] } }
        },
        {
          Sid      = "ReadWriteOnlyItsStateObject"
          Effect   = "Allow"
          Action   = ["s3:GetObject", "s3:PutObject"]
          Resource = "${aws_s3_bucket.state.arn}/${key}"
        },
        {
          Sid      = "LockOnlyItsStateLockfile"
          Effect   = "Allow"
          Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
          Resource = "${aws_s3_bucket.state.arn}/${key}.tflock"
        }
      ]
    })
  }
}

resource "aws_s3_bucket" "state" {
  bucket        = var.state_bucket_name
  force_destroy = false
  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "state_https_only" {
  bucket = aws_s3_bucket.state.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

resource "aws_s3_bucket" "artifact" {
  bucket        = var.artifact_bucket_name
  force_destroy = false
  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket_versioning" "artifact" {
  bucket = aws_s3_bucket.artifact.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifact" {
  bucket = aws_s3_bucket.artifact.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "artifact" {
  bucket                  = aws_s3_bucket.artifact.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "artifact_https_only" {
  bucket = aws_s3_bucket.artifact.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.artifact.arn, "${aws_s3_bucket.artifact.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

resource "aws_iam_role" "launcher" {
  for_each             = var.launchers
  name                 = "oficina-${each.key}-launcher"
  assume_role_policy   = local.launcher_trust_policies[each.key]
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "launcher" {
  for_each = var.launchers
  name     = "launch-reviewed-artifact-only"
  role     = aws_iam_role.launcher[each.key].id
  policy   = local.launcher_permission_policies[each.key]
}

resource "aws_iam_policy" "state_access" {
  for_each = var.state_keys
  name     = "oficina-state-${each.key}-access"
  policy   = local.state_access_policies[each.key]
}

resource "terraform_data" "role_separation" {
  input = { launchers = local.launcher_role_arns, runtimes = var.runtime_role_arns }
  lifecycle {
    precondition {
      condition     = length(setintersection(local.launcher_role_arns, var.runtime_role_arns)) == 0
      error_message = "GitHub launcher roles and workload runtime roles must be distinct."
    }
  }
}
