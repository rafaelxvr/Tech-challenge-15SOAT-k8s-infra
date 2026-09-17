mock_provider "aws" {}

variables {
  account_id               = "123456789012"
  state_bucket_name        = "oficina-phase3-state-example"
  artifact_bucket_name     = "oficina-phase3-artifacts-example"
  github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  state_keys = {
    bootstrap = "bootstrap/terraform.tfstate"
    staging   = "environments/staging/terraform.tfstate"
  }
  launchers = {
    k8s_staging = {
      repository            = "example/oficina-k8s-infra"
      github_subject_prefix = "repo:example@101/oficina-k8s-infra@202"
      environment           = "staging"
      branch                = "develop"
      source_prefix         = "releases/k8s/staging"
      codebuild_project_arn = "arn:aws:codebuild:us-east-1:123456789012:project/oficina-k8s-staging"
    }
    k8s_production = {
      repository            = "example/oficina-k8s-infra"
      github_subject_prefix = "repo:example@101/oficina-k8s-infra@202"
      environment           = "production"
      branch                = "main"
      source_prefix         = "releases/k8s/production"
      codebuild_project_arn = "arn:aws:codebuild:us-east-1:123456789012:project/oficina-k8s-production"
    }
  }
}

run "state_is_protected" {
  command = apply

  assert {
    condition     = aws_s3_bucket_versioning.state.versioning_configuration[0].status == "Enabled"
    error_message = "State versions must survive an accidental overwrite."
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.state.block_public_acls && aws_s3_bucket_public_access_block.state.block_public_policy && aws_s3_bucket_public_access_block.state.ignore_public_acls && aws_s3_bucket_public_access_block.state.restrict_public_buckets
    error_message = "State must block every public access path."
  }

  assert {
    condition     = aws_s3_bucket.state.force_destroy == false && aws_s3_bucket.artifact.force_destroy == false
    error_message = "Buckets must retain data unless an operator explicitly destroys it outside this module."
  }

  assert {
    condition     = can(regex("aws:SecureTransport", aws_s3_bucket_policy.state_https_only.policy))
    error_message = "State bucket policy must deny non-HTTPS requests."
  }
}

run "trust_subjects_are_environment_scoped" {
  command = plan

  assert {
    condition = alltrue([for environment in ["staging", "production"] :
      jsondecode(output.launcher_trust_policies["k8s_${environment}"]).Statement[0].Condition == {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:example@101/oficina-k8s-infra@202:environment:${environment}"
        }
      }
    ])
    error_message = "Both trust policies must retain exactly the reviewed immutable owner/repository IDs and their environment, using StringEquals and the STS audience only."
  }

  assert {
    condition     = output.launcher_trust_subjects["k8s_staging"] == "repo:example@101/oficina-k8s-infra@202:environment:staging"
    error_message = "Staging trust must be an exact environment subject, not a wildcard or pull-request subject."
  }

  assert {
    condition     = can(regex("sts.amazonaws.com", output.launcher_trust_policies["k8s_production"]))
    error_message = "GitHub OIDC trust must require sts.amazonaws.com audience."
  }

  assert {
    condition = (
      one([for statement in jsondecode(local.launcher_permission_policies["k8s_staging"]).Statement : statement if statement.Sid == "DenyBuildspecOverride"]).Effect == "Deny" &&
      one([for statement in jsondecode(local.launcher_permission_policies["k8s_staging"]).Statement : statement if statement.Sid == "DenyBuildspecOverride"]).Action == "codebuild:StartBuild" &&
      one([for statement in jsondecode(local.launcher_permission_policies["k8s_staging"]).Statement : statement if statement.Sid == "DenyBuildspecOverride"]).Resource == var.launchers["k8s_staging"].codebuild_project_arn &&
      one([for statement in jsondecode(local.launcher_permission_policies["k8s_staging"]).Statement : statement if statement.Sid == "DenyBuildspecOverride"]).Condition.Null["codebuild:source.buildspec"] == "false"
    )
    error_message = "The parsed launcher IAM policy must deny only StartBuild requests that supply buildspecOverride, on its exact project."
  }

  assert {
    condition = (
      one([for statement in jsondecode(local.launcher_permission_policies["k8s_staging"]).Statement : statement if statement.Sid == "StartOnlyItsDeploymentProject"]).Effect == "Allow" &&
      contains(one([for statement in jsondecode(local.launcher_permission_policies["k8s_staging"]).Statement : statement if statement.Sid == "StartOnlyItsDeploymentProject"]).Action, "codebuild:StartBuild") &&
      one([for statement in jsondecode(local.launcher_permission_policies["k8s_staging"]).Statement : statement if statement.Sid == "StartOnlyItsDeploymentProject"]).Resource == var.launchers["k8s_staging"].codebuild_project_arn &&
      one([for statement in jsondecode(local.launcher_permission_policies["k8s_staging"]).Statement : statement if statement.Sid == "DenyBuildspecOverride"]).Condition.Null["codebuild:source.buildspec"] == "false"
    )
    error_message = "An ordinary StartBuild without buildspecOverride remains allowed for the exact reviewed project."
  }

  assert {
    condition = (
      one([for statement in jsondecode(local.launcher_permission_policies["k8s_staging"]).Statement : statement if statement.Sid == "DenyDeploymentControlOverrides"]).Effect == "Deny" &&
      one([for statement in jsondecode(local.launcher_permission_policies["k8s_staging"]).Statement : statement if statement.Sid == "DenyDeploymentControlOverrides"]).Action == "codebuild:StartBuild" &&
      one([for statement in jsondecode(local.launcher_permission_policies["k8s_staging"]).Statement : statement if statement.Sid == "DenyDeploymentControlOverrides"]).Resource == var.launchers["k8s_staging"].codebuild_project_arn &&
      toset(one([for statement in jsondecode(local.launcher_permission_policies["k8s_staging"]).Statement : statement if statement.Sid == "DenyDeploymentControlOverrides"]).Condition["ForAnyValue:StringEquals"]["codebuild:environment.environmentVariables.name"]) == toset(["DEPLOYMENT_MODE", "DEPLOYMENT_TFVARS_PATH"])
    )
    error_message = "The parsed launcher IAM policy must deny only mode and tfvars StartBuild environment overrides on its exact project."
  }

  assert {
    condition = (
      one([for statement in jsondecode(local.launcher_permission_policies["k8s_staging"]).Statement : statement if statement.Sid == "ReadOnlyVersionedFoundationOutputArtifact"]).Effect == "Allow" &&
      toset(one([for statement in jsondecode(local.launcher_permission_policies["k8s_staging"]).Statement : statement if statement.Sid == "ReadOnlyVersionedFoundationOutputArtifact"]).Action) == toset(["s3:GetObject", "s3:GetObjectVersion"]) &&
      one([for statement in jsondecode(local.launcher_permission_policies["k8s_staging"]).Statement : statement if statement.Sid == "ReadOnlyVersionedFoundationOutputArtifact"]).Resource == "${aws_s3_bucket.artifact.arn}/releases/k8s/foundation/outputs/*"
    )
    error_message = "Kubernetes launchers may read only the immutable foundation output prefix."
  }
}

run "foundation_output_reads_only_for_proven_consumers" {
  command = plan
  variables {
    launchers = { for item in flatten([for component, repository in {
      k8s        = "Tech-challenge-15SOAT-k8s-infra"
      database   = "Tech-challenge-15SOAT-db-infra"
      functions  = "Tech-challenge-15SOAT-functions"
      app        = "Tech-challenge-15SOAT"
      unreviewed = "unreviewed-db-infra"
      } : [for environment in ["staging", "production"] : {
        name = "${component}_${environment}"
        launcher = {
          repository            = "rafaelxvr/${repository}"
          github_subject_prefix = "repo:rafaelxvr@101/${repository}@202"
          environment           = environment
          branch                = environment == "staging" ? "develop" : "main"
          source_prefix         = "releases/${component == "unreviewed" ? "database" : component}/${environment}"
          codebuild_project_arn = "arn:aws:codebuild:us-east-1:123456789012:project/oficina-${component}-${environment}"
        }
    }]]) : item.name => item.launcher }
  }
  assert {
    condition = alltrue([for name, policy in local.launcher_permission_policies :
      jsonencode([for statement in jsondecode(policy).Statement : statement if statement.Sid == "ReadOnlyVersionedFoundationOutputArtifact"]) == jsonencode(
        startswith(name, "k8s_") || startswith(name, "database_") ? [{
          Sid      = "ReadOnlyVersionedFoundationOutputArtifact"
          Effect   = "Allow"
          Action   = ["s3:GetObject", "s3:GetObjectVersion"]
          Resource = "${aws_s3_bucket.artifact.arn}/releases/k8s/foundation/outputs/*"
        }] : []
      )
    ])
    error_message = "Only K8S and the reviewed DB repository may read the exact versioned foundation outputs prefix; APP, functions and a lookalike database-prefix repository receive no grant."
  }
  assert {
    condition = alltrue([for name, policy in local.launcher_permission_policies :
      length([for statement in jsondecode(policy).Statement : statement if statement.Effect == "Deny" && contains(["DenyBuildspecOverride", "DenyDeploymentControlOverrides"], statement.Sid)]) == 2 &&
      one([for statement in jsondecode(policy).Statement : statement if statement.Sid == "UploadOnlyReviewedSourcePrefix"]).Resource == "${aws_s3_bucket.artifact.arn}/${var.launchers[name].source_prefix}/*"
    ])
    error_message = "Foundation receipt reads must preserve build/control denials and each launcher's existing writable source prefix."
  }
}

run "database_foundation_reads_require_exact_environment_prefix" {
  command = plan
  variables {
    launchers = { for environment in ["staging", "production"] : "database_${environment}" => {
      repository            = "rafaelxvr/Tech-challenge-15SOAT-db-infra"
      github_subject_prefix = "repo:rafaelxvr@101/Tech-challenge-15SOAT-db-infra@202"
      environment           = environment
      branch                = environment == "staging" ? "develop" : "main"
      source_prefix         = "releases/database/${environment}/unreviewed"
      codebuild_project_arn = "arn:aws:codebuild:us-east-1:123456789012:project/oficina-database-${environment}"
    } }
  }
  assert {
    condition = alltrue([for policy in values(local.launcher_permission_policies) :
      !contains([for statement in jsondecode(policy).Statement : statement.Sid], "ReadOnlyVersionedFoundationOutputArtifact")
    ])
    error_message = "The DB repository alone must not grant foundation reads outside its exact reviewed environment source prefix."
  }
}

run "rejects_wrong_branch_for_environment" {
  command = plan

  variables {
    launchers = {
      invalid = {
        repository            = "example/oficina-k8s-infra"
        github_subject_prefix = "repo:example@101/oficina-k8s-infra@202"
        environment           = "production"
        branch                = "develop"
        source_prefix         = "releases/k8s/production"
        codebuild_project_arn = "arn:aws:codebuild:us-east-1:123456789012:project/oficina-k8s-production"
      }
    }
  }

  expect_failures = [var.launchers]
}

run "allows_only_exact_foundation_addons_target_for_k8s_staging" {
  command = plan

  variables {
    launchers = {
      kubernetes-staging = {
        repository                        = "rafaelxvr/Tech-challenge-15SOAT-k8s-infra"
        github_subject_prefix             = "repo:rafaelxvr@101/Tech-challenge-15SOAT-k8s-infra@202"
        environment                       = "staging"
        branch                            = "develop"
        source_prefix                     = "releases/k8s/staging"
        codebuild_project_arn             = "arn:aws:codebuild:us-east-1:123456789012:project/oficina-k8s-staging"
        additional_codebuild_project_arns = ["arn:aws:codebuild:us-east-1:123456789012:project/oficina-phase3-foundation-addons"]
      }
    }
  }

  assert {
    condition     = one([for statement in jsondecode(local.launcher_permission_policies["kubernetes-staging"]).Statement : statement if statement.Sid == "StartOnlyReviewedAdditionalProject"]).Resource == ["arn:aws:codebuild:us-east-1:123456789012:project/oficina-phase3-foundation-addons"]
    error_message = "Only the reviewed K8S staging launcher may start the exact foundation-addons project."
  }
}

run "rejects_any_other_foundation_addons_target" {
  command = plan

  variables {
    launchers = {
      kubernetes-staging = {
        repository                        = "rafaelxvr/Tech-challenge-15SOAT-k8s-infra"
        github_subject_prefix             = "repo:rafaelxvr@101/Tech-challenge-15SOAT-k8s-infra@202"
        environment                       = "staging"
        branch                            = "develop"
        source_prefix                     = "releases/k8s/staging"
        codebuild_project_arn             = "arn:aws:codebuild:us-east-1:123456789012:project/oficina-k8s-staging"
        additional_codebuild_project_arns = ["arn:aws:codebuild:us-east-1:123456789012:project/unreviewed-project"]
      }
    }
  }

  expect_failures = [var.launchers]
}

run "rejects_foundation_addons_from_former_k8s_launcher_name" {
  command = plan

  variables {
    launchers = {
      k8s-staging = {
        repository                        = "rafaelxvr/Tech-challenge-15SOAT-k8s-infra"
        github_subject_prefix             = "repo:rafaelxvr@101/Tech-challenge-15SOAT-k8s-infra@202"
        environment                       = "staging"
        branch                            = "develop"
        source_prefix                     = "releases/k8s/staging"
        codebuild_project_arn             = "arn:aws:codebuild:us-east-1:123456789012:project/oficina-k8s-staging"
        additional_codebuild_project_arns = ["arn:aws:codebuild:us-east-1:123456789012:project/oficina-phase3-foundation-addons"]
      }
    }
  }

  expect_failures = [var.launchers]
}

run "rejects_foundation_addons_from_another_repository" {
  command = plan

  variables {
    launchers = {
      kubernetes-staging = {
        repository                        = "another-owner/Tech-challenge-15SOAT-k8s-infra"
        github_subject_prefix             = "repo:another-owner@101/Tech-challenge-15SOAT-k8s-infra@202"
        environment                       = "staging"
        branch                            = "develop"
        source_prefix                     = "releases/k8s/staging"
        codebuild_project_arn             = "arn:aws:codebuild:us-east-1:123456789012:project/oficina-k8s-staging"
        additional_codebuild_project_arns = ["arn:aws:codebuild:us-east-1:123456789012:project/oficina-phase3-foundation-addons"]
      }
    }
  }

  expect_failures = [var.launchers]
}

run "rejects_oidc_provider_from_another_account" {
  command = plan

  variables {
    github_oidc_provider_arn = "arn:aws:iam::210987654321:oidc-provider/token.actions.githubusercontent.com"
  }

  expect_failures = [var.github_oidc_provider_arn]
}

run "rejects_codebuild_project_outside_approved_account_or_region" {
  command = plan

  variables {
    launchers = {
      invalid = {
        repository            = "example/oficina-k8s-infra"
        github_subject_prefix = "repo:example@101/oficina-k8s-infra@202"
        environment           = "staging"
        branch                = "develop"
        source_prefix         = "releases/k8s/staging"
        codebuild_project_arn = "arn:aws:codebuild:us-west-2:210987654321:project/oficina-k8s-staging"
      }
    }
  }

  expect_failures = [var.launchers]
}

run "rejects_runtime_role_from_another_account" {
  command = plan

  variables {
    runtime_role_arns = ["arn:aws:iam::210987654321:role/oficina-runtime"]
  }

  expect_failures = [var.runtime_role_arns]
}

run "rejects_legacy_subject_prefix" {
  command = plan
  variables {
    launchers = {
      invalid = {
        repository            = "example/oficina-k8s-infra"
        github_subject_prefix = "repo:example/oficina-k8s-infra"
        environment           = "staging"
        branch                = "develop"
        source_prefix         = "releases/k8s/staging"
        codebuild_project_arn = "arn:aws:codebuild:us-east-1:123456789012:project/oficina-k8s-staging"
      }
    }
  }
  expect_failures = [var.launchers]
}

run "rejects_wildcard_subject_prefix" {
  command = plan
  variables {
    launchers = {
      invalid = {
        repository            = "example/oficina-k8s-infra"
        github_subject_prefix = "repo:example@101/oficina-k8s-infra@*"
        environment           = "staging"
        branch                = "develop"
        source_prefix         = "releases/k8s/staging"
        codebuild_project_arn = "arn:aws:codebuild:us-east-1:123456789012:project/oficina-k8s-staging"
      }
    }
  }
  expect_failures = [var.launchers]
}

run "rejects_another_repository_subject_prefix" {
  command = plan
  variables {
    launchers = {
      invalid = {
        repository            = "example/oficina-k8s-infra"
        github_subject_prefix = "repo:example@101/another-repo@202"
        environment           = "staging"
        branch                = "develop"
        source_prefix         = "releases/k8s/staging"
        codebuild_project_arn = "arn:aws:codebuild:us-east-1:123456789012:project/oficina-k8s-staging"
      }
    }
  }
  expect_failures = [var.launchers]
}

run "rejects_embedded_environment_subject_prefix" {
  command = plan
  variables {
    launchers = {
      invalid = {
        repository            = "example/oficina-k8s-infra"
        github_subject_prefix = "repo:example@101/oficina-k8s-infra@202:environment:production"
        environment           = "staging"
        branch                = "develop"
        source_prefix         = "releases/k8s/staging"
        codebuild_project_arn = "arn:aws:codebuild:us-east-1:123456789012:project/oficina-k8s-staging"
      }
    }
  }
  expect_failures = [var.launchers]
}

run "rejects_missing_owner_id_subject_prefix" {
  command = plan
  variables {
    launchers = {
      invalid = {
        repository            = "example/oficina-k8s-infra"
        github_subject_prefix = "repo:example/oficina-k8s-infra@202"
        environment           = "staging"
        branch                = "develop"
        source_prefix         = "releases/k8s/staging"
        codebuild_project_arn = "arn:aws:codebuild:us-east-1:123456789012:project/oficina-k8s-staging"
      }
    }
  }
  expect_failures = [var.launchers]
}
