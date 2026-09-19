mock_provider "aws" {}

variables {
  name                              = "oficina-phase3"
  aws_region                        = "us-east-1"
  account_id                        = "123456789012"
  cluster_name                      = "oficina-phase3"
  cluster_arn                       = "arn:aws:eks:us-east-1:123456789012:cluster/oficina-phase3"
  cluster_endpoint                  = "https://private.eks.example"
  cluster_ca_certificate            = "Y2E="
  vpc_id                            = "vpc-12345678"
  private_subnet_ids                = ["subnet-12345678"]
  security_group_ids                = ["sg-12345678"]
  artifact_bucket_name              = "oficina-artifacts-test"
  state_bucket_name                 = "oficina-state-test"
  deployer_repository_url           = "123456789012.dkr.ecr.us-east-1.amazonaws.com/deployer"
  deployer_image_digest             = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  vpc_id_for_controller             = "vpc-12345678"
  load_balancer_controller_role_arn = "arn:aws:iam::123456789012:role/load-balancer-controller"
}

run "create_only_declared_build_log_group" {
  command = plan

  assert {
    condition = one([
      for statement in jsondecode(local.policy).Statement : statement
      if statement.Sid == "CreateOnlyThisBuildLogGroup"
      ]) == {
      Sid      = "CreateOnlyThisBuildLogGroup"
      Effect   = "Allow"
      Action   = "logs:CreateLogGroup"
      Resource = "arn:aws:logs:us-east-1:123456789012:log-group:/aws/codebuild/oficina-phase3-foundation-addons"
    }
    error_message = "The service role must create only its exact declared log group, without a wildcard or log-stream suffix."
  }

  assert {
    condition = one([
      for statement in jsondecode(local.policy).Statement : statement
      if statement.Sid == "WriteOnlyThisBuildLogGroup"
      ]) == {
      Sid      = "WriteOnlyThisBuildLogGroup"
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "arn:aws:logs:us-east-1:123456789012:log-group:/aws/codebuild/oficina-phase3-foundation-addons:log-stream:*"
    }
    error_message = "Existing write permission must stay restricted to streams in the same group."
  }

  assert {
    condition = length([
      for statement in jsondecode(local.policy).Statement : statement
      if anytrue([for action in flatten([statement.Action]) : startswith(action, "logs:")])
    ]) == 2
    error_message = "Only the exact group-creation and stream-write statements may grant Logs actions."
  }

  assert {
    condition     = aws_codebuild_project.foundation_addons.logs_config[0].cloudwatch_logs[0].group_name == "/aws/codebuild/oficina-phase3-foundation-addons"
    error_message = "The project must declare the same log group authorized by its role."
  }
}

run "prerequisites_shared_lock_is_conditional" {
  command = plan
  assert {
    condition = [for statement in jsondecode(local.policy).Statement : statement if endswith(try(tostring(statement.Resource), ""), "/deployment-locks/shared-foundation.json")] == [
      {
        Sid = "ReadSharedStagingPrerequisitesLock", Effect = "Allow", Action = "s3:GetObject", Resource = "arn:aws:s3:::oficina-state-test/deployment-locks/shared-foundation.json"
      },
      {
        Sid = "AcquireSharedStagingPrerequisitesLockConditionally", Effect = "Allow", Action = "s3:PutObject", Resource = "arn:aws:s3:::oficina-state-test/deployment-locks/shared-foundation.json",
        Condition = { StringEquals = { "s3:if-none-match" = "*" } }
      },
      {
        Sid = "ReleaseSharedStagingPrerequisitesLockConditionally", Effect = "Allow", Action = "s3:DeleteObject", Resource = "arn:aws:s3:::oficina-state-test/deployment-locks/shared-foundation.json",
        Condition = { Null = { "s3:if-match" = "false" }, StringNotEquals = { "s3:if-match" = "*" } }
      }
    ]
    error_message = "Only the exact shared lock may be read, created with If-None-Match *, or deleted with a non-wildcard If-Match."
  }
  assert {
    condition = alltrue([for statement in jsondecode(local.policy).Statement : alltrue([
      for action in flatten([statement.Action]) : !startswith(action, "iam:") && !startswith(action, "kms:") && !contains(["s3:GetObjectVersion", "s3:DeleteObjectVersion", "s3:ListBucketVersions"], action)
    ]) if statement.Sid != "ReadOnlyFoundationAddonsBundle"])
    error_message = "Runtime lock access must not grant diagnostic IAM, KMS, or state version permissions."
  }
  assert {
    condition = one([for statement in jsondecode(local.policy).Statement : statement if statement.Sid == "ListOnlyFoundationAddonsState"]).Condition.StringLike["s3:prefix"] == ["foundation-addons/terraform.tfstate", "foundation-addons/terraform.tfstate.tflock"]
    error_message = "No new ListBucket permission may be added for diagnostic convenience."
  }
}