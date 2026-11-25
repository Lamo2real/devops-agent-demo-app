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

variable "app_version" {
  type        = string
  description = "Git commit of the deployed code; shown by GET /health and in logs."
  default     = "dev"
}

variable "alarm_prefix" {
  type        = string
  description = "Alarm name prefix that starts AWS DevOps Agent investigations (ALARM_NAME_PREFIXES of the agent template)."
  default     = "symptom-"
}

variable "web_origins" {
  type        = list(string)
  description = "Browser origins allowed to call the API (CORS): the GitHub Pages site of the game, and localhost for development."
  default     = ["http://localhost:8080"]
}

variable "traffic_enabled" {
  type        = bool
  description = "Run the synthetic traffic generator (one journey per minute)."
  default     = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
