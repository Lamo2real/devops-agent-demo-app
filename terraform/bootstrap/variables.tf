variable "app_name" {
  type = string
}

variable "environment" {
  type = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,15}$", var.environment)) && length("${var.app_name}-${var.environment}") <= 36
    error_message = "environment: lowercase, max 16 characters; app_name-environment max 36 characters."
  }
}

variable "aws_account_id" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "state_bucket_name" {
  type        = string
  description = "Existing Terraform state bucket (created by the agent template bootstrap)."
}

variable "github_repository" {
  type = string
  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must be owner/repo."
  }
}

variable "github_oidc_sub_prefix" {
  type        = string
  description = "Empty = repo:<github_repository>; immutable-subject repos use repo:<owner>@<id>/<repo>@<id>."
  default     = ""
}

variable "alarm_prefix" {
  type        = string
  description = "Alarm name prefix of the main stack (agent investigations start for alarms with this prefix)."
  default     = "symptom-"
}

variable "tags" {
  type    = map(string)
  default = {}
}
