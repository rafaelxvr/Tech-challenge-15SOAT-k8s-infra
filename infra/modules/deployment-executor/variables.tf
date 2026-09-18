variable "name" { type = string }
variable "aws_region" { type = string }
variable "account_id" { type = string }
variable "vpc_id" { type = string }
variable "cluster_arn" { type = string }
variable "node_group_arns" { type = list(string) }
variable "kubernetes_repository" {
  type        = string
  description = "Repository identity that alone owns EKS node-group updates. Its staging and production executors receive the narrow update actions."
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9._-]*$", var.kubernetes_repository))
    error_message = "kubernetes_repository must be a lowercase repository identifier."
  }
}
variable "artifact_bucket_name" { type = string }
variable "state_bucket_name" {
  type        = string
  description = "Existing bootstrap state bucket. Executors receive only their own state and lockfile paths."
}
variable "private_subnet_ids" { type = list(string) }
variable "security_group_ids" { type = list(string) }
variable "function_gateway_bindings" {
  type = map(object({
    api_id                      = string
    authorizer_id               = string
    challenge_integration_id    = string
    verification_integration_id = string
    challenge_route_id          = string
    verification_route_id       = string
  }))
  default     = {}
  description = "Reviewed FUN-owned API Gateway v2 resource IDs per environment. Missing bindings deliberately omit FUN gateway permissions until the two-phase handoff is reviewed."
  validation {
    condition = (length(setsubtract(toset(keys(var.function_gateway_bindings)), toset(["staging", "production"]))) == 0 &&
      length(distinct([for binding in values(var.function_gateway_bindings) : binding.api_id])) == length(values(var.function_gateway_bindings)) &&
      alltrue([
        for binding in values(var.function_gateway_bindings) : alltrue([
          can(regex("^[a-z0-9]{6,16}$", binding.api_id)),
          can(regex("^[A-Za-z0-9]{3,64}$", binding.authorizer_id)),
          can(regex("^[A-Za-z0-9]{3,64}$", binding.challenge_integration_id)),
          can(regex("^[A-Za-z0-9]{3,64}$", binding.verification_integration_id)),
          can(regex("^[A-Za-z0-9]{3,64}$", binding.challenge_route_id)),
          can(regex("^[A-Za-z0-9]{3,64}$", binding.verification_route_id))
        ])
    ]))
    error_message = "function_gateway_bindings must contain bounded reviewed FUN authorizer, integration and CPF route IDs, with distinct staging/production API IDs."
  }
}
variable "newrelic_layer_version_arns" {
  type        = object({ java_slim = string, extension = string })
  default     = null
  description = "Reviewed immutable New Relic layer version ARNs. Null fails closed by omitting layer-read access until pinned versions are supplied."
  validation {
    condition = var.newrelic_layer_version_arns == null || (
      can(regex("^arn:aws:lambda:us-east-1:451483290750:layer:NewRelicJava17:[1-9][0-9]*$", var.newrelic_layer_version_arns.java_slim)) &&
      can(regex("^arn:aws:lambda:us-east-1:451483290750:layer:NewRelicLambdaExtension:[1-9][0-9]*$", var.newrelic_layer_version_arns.extension))
    )
    error_message = "New Relic layer inputs must be exact pinned Java17 and Extension version ARNs from the reviewed publisher account; placeholders and wildcards are forbidden."
  }
}
variable "deployer_image_digest" {
  type        = string
  description = "Immutable SHA-256 digest produced by the reviewed GitHub platform-image workflow."
  validation {
    condition     = can(regex("^sha256:[a-f0-9]{64}$", var.deployer_image_digest))
    error_message = "deployer_image_digest must be a lowercase immutable SHA-256 image digest."
  }
}

variable "application_bootstrap_secret_refs" {
  type = map(object({
    database_arn = string
    master       = object({ arn = string, version_id = string, database_arn = string })
    migration    = object({ arn = string, version_id = string })
    app          = object({ arn = string, version_id = string })
    auth         = object({ arn = string, version_id = string })
    notification = object({ arn = string, version_id = string })
  }))
  default     = {}
  description = "Optional reviewed APP bootstrap references. Only staging is accepted; version IDs are carried into the reviewed input while IAM is scoped to exact ARNs."
  validation {
    condition = length(setsubtract(toset(keys(var.application_bootstrap_secret_refs)), toset(["staging"]))) == 0 && alltrue([
      for environment, refs in var.application_bootstrap_secret_refs :
      refs.database_arn == "arn:aws:rds:${var.aws_region}:${var.account_id}:db:${var.name}-${environment}-postgres" &&
      refs.master.database_arn == refs.database_arn &&
      can(regex("^arn:aws:secretsmanager:${var.aws_region}:${var.account_id}:secret:rds!db-[A-Za-z0-9-]+$", refs.master.arn)) &&
      alltrue([
        for key in ["migration", "app", "auth", "notification"] :
        can(regex("^arn:aws:secretsmanager:${var.aws_region}:${var.account_id}:secret:oficina/${environment}/${key}-[A-Za-z0-9]{6}$", refs[key].arn))
      ]) &&
      alltrue([
        for reference in [refs.master, refs.migration, refs.app, refs.auth, refs.notification] :
        can(regex("^[A-Za-z0-9-]{32,64}$", reference.version_id))
      ])
    ])
    error_message = "application_bootstrap_secret_refs accepts only staging and requires exact same-account RDS/runtime secret ARNs plus immutable 32-64 character version IDs."
  }
}

variable "deployments" {
  type = map(object({
    repository               = string
    environment              = string
    source_prefix            = string
    terraform_state_key      = string
    deployment_mode          = string
    terraform_variables_path = string
  }))
  description = "Exactly four repositories multiplied by staging and production. Source bundles arrive through S3, never GitHub credentials in CodeBuild."
  validation {
    condition = alltrue([
      for deployment in values(var.deployments) :
      deployment.source_prefix == "releases/app/staging"
      if deployment.repository == "oficina-app" && deployment.environment == "staging"
    ])
    error_message = "The oficina-app staging source_prefix must be releases/app/staging, matching the APP launcher contract and executor S3 read scope."
  }
  validation {
    condition = length(var.deployments) == 8 && length(distinct([for deployment in values(var.deployments) : deployment.repository])) == 4 && length(distinct([for deployment in values(var.deployments) : deployment.terraform_state_key])) == length(var.deployments) && alltrue([
      for deployment in values(var.deployments) :
      contains(["staging", "production"], deployment.environment) &&
      can(regex("^[a-z0-9][a-z0-9/_-]*$", deployment.source_prefix)) &&
      can(regex("^[a-z0-9][a-z0-9/_-]*\\.tfstate$", deployment.terraform_state_key)) &&
      contains(["plan", "apply"], deployment.deployment_mode) &&
      can(regex("^/tmp/oficina/[a-z0-9_-]+\\.tfvars\\.json$", deployment.terraform_variables_path))
      ]) && contains(distinct([for deployment in values(var.deployments) : deployment.repository]), var.kubernetes_repository) && alltrue([
      for repository in distinct([for deployment in values(var.deployments) : deployment.repository]) :
      length([for deployment in values(var.deployments) : deployment.environment if deployment.repository == repository]) == 2 &&
      toset([for deployment in values(var.deployments) : deployment.environment if deployment.repository == repository]) == toset(["staging", "production"])
    ])
    error_message = "deployments must contain exactly four repositories, each with one staging and one production project and a bounded S3 source prefix."
  }
}
