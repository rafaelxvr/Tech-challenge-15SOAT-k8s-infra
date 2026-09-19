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

run "prerequisites_shared_lock_is_one_object" {
  command = plan
  assert {
    condition = one([for statement in jsondecode(local.policy).Statement : statement if statement.Sid == "SharedStagingPrerequisitesLock"]) == {
      Sid = "SharedStagingPrerequisitesLock", Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = "arn:aws:s3:::oficina-state-test/deployment-locks/shared-foundation.json"
    }
    error_message = "Prerequisite mode may touch only the existing shared deployment lock; no APP RBAC or production resources."
  }
}
