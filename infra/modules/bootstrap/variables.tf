variable "account_id" {
  type        = string
  description = "Verified AWS account ID. It is used only to validate resource ARNs."

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account ID."
  }
}

variable "state_bucket_name" {
  type        = string
  description = "Globally unique bucket for Terraform state and S3 lockfiles."

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.state_bucket_name))
    error_message = "state_bucket_name must be a valid S3 bucket name."
  }
}

variable "artifact_bucket_name" {
  type        = string
  description = "Globally unique, versioned bucket for immutable deployment bundles."

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.artifact_bucket_name))
    error_message = "artifact_bucket_name must be a valid S3 bucket name."
  }
}

variable "github_oidc_provider_arn" {
  type        = string
  description = "Existing GitHub Actions OIDC provider ARN in the verified AWS account."

  validation {
    condition = can(regex(
      "^arn:aws:iam::${var.account_id}:oidc-provider/token\\.actions\\.githubusercontent\\.com$",
      var.github_oidc_provider_arn
    ))
    error_message = "github_oidc_provider_arn must identify token.actions.githubusercontent.com."
  }
}

variable "state_keys" {
  type        = map(string)
  description = "Dedicated state object key for every Terraform root. The lockfile is the same key plus .tflock."

  validation {
    condition     = length(var.state_keys) > 0 && alltrue([for key in values(var.state_keys) : can(regex("^[a-z0-9][a-z0-9/_-]*\\.tfstate$", key))])
    error_message = "state_keys must contain non-empty, lowercase .tfstate object keys."
  }
}

variable "launchers" {
  type = map(object({
    repository                        = string
    environment                       = string
    branch                            = string
    source_prefix                     = string
    codebuild_project_arn             = string
    additional_codebuild_project_arns = optional(set(string), [])
  }))
  description = "GitHub repository/environment launchers. Subjects are derived, never supplied by a pull request."

  validation {
    condition = length(var.launchers) > 0 && alltrue([
      for launcher in values(var.launchers) :
      can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", launcher.repository)) &&
      contains(["staging", "production"], launcher.environment) &&
      can(regex("^[a-z0-9][a-z0-9/_-]*$", launcher.source_prefix)) &&
      can(regex("^arn:aws:codebuild:us-east-1:${var.account_id}:project/[A-Za-z0-9_.-]+$", launcher.codebuild_project_arn)) &&
      alltrue([for arn in launcher.additional_codebuild_project_arns : can(regex("^arn:aws:codebuild:us-east-1:${var.account_id}:project/[A-Za-z0-9_.-]+$", arn))])
    ])
    error_message = "Each launcher needs a repository, approved environment, source prefix, and exact CodeBuild project ARN."
  }

  validation {
    condition = alltrue([
      for launcher in values(var.launchers) :
      (launcher.environment == "staging" && launcher.branch == "develop") ||
      (launcher.environment == "production" && launcher.branch == "main")
    ])
    error_message = "Staging launchers must use develop and production launchers must use main. Pull-request subjects never receive a role."
  }

  validation {
    condition = alltrue([
      for name, launcher in var.launchers : length(launcher.additional_codebuild_project_arns) == 0 || (
        name == "k8s-staging" && can(regex("^[A-Za-z0-9_.-]+/oficina-k8s-infra$", launcher.repository)) && launcher.environment == "staging" && launcher.branch == "develop" && launcher.source_prefix == "releases/k8s/staging" && launcher.additional_codebuild_project_arns == toset(["arn:aws:codebuild:us-east-1:${var.account_id}:project/oficina-phase3-foundation-addons"])
      )
    ])
    error_message = "Only the oficina-k8s-infra staging launcher may target the exact foundation-addons CodeBuild project."
  }
}

variable "runtime_role_arns" {
  type        = set(string)
  description = "Runtime role ARNs reserved for workloads. They must not overlap GitHub launcher roles."
  default     = []

  validation {
    condition     = alltrue([for arn in var.runtime_role_arns : can(regex("^arn:aws:iam::${var.account_id}:role/.+$", arn))])
    error_message = "runtime_role_arns must contain IAM role ARNs in account_id only."
  }
}
