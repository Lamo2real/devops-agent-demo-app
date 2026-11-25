# One-time setup by an administrator (scripts/bootstrap.sh): the permissions
# boundary and the GitHub Actions OIDC roles for this app. It reuses the
# account's existing Terraform state bucket and GitHub OIDC provider.

terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
  }
  backend "s3" {}
}

provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.aws_account_id]
  default_tags {
    tags = var.tags
  }
}

data "aws_partition" "current" {}

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

locals {
  prefix     = "${var.app_name}-${var.environment}"
  partition  = data.aws_partition.current.partition
  account    = var.aws_account_id
  iam        = "arn:${local.partition}:iam::${local.account}"
  sub_prefix = var.github_oidc_sub_prefix != "" ? var.github_oidc_sub_prefix : "repo:${var.github_repository}"

  bucket_arn     = "arn:${local.partition}:s3:::${var.state_bucket_name}"
  state_key      = "demo-app/${local.prefix}.tfstate"
  role_glob      = "${local.iam}:role/${local.prefix}-fn-*"
  ci_role_glob   = "${local.iam}:role/${local.prefix}-github-*"
  boundary_name  = "${local.prefix}-boundary"
  boundary_arn   = "${local.iam}:policy/${local.boundary_name}"
  table_arn_glob = "arn:${local.partition}:dynamodb:${var.aws_region}:${local.account}:table/${local.prefix}-*"
  alarm_arn_glob = "arn:${local.partition}:cloudwatch:${var.aws_region}:${local.account}:alarm:${var.alarm_prefix}${local.prefix}-*"
}

# Every Lambda role of the app must carry this boundary (the deploy role cannot
# create one without it), so pushed code cannot mint a more powerful role.
data "aws_iam_policy_document" "boundary" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:${local.partition}:logs:${var.aws_region}:${local.account}:log-group:/aws/lambda/${local.prefix}-*:*"]
  }
  statement {
    sid       = "Scores"
    actions   = ["dynamodb:PutItem", "dynamodb:Query"]
    resources = [local.table_arn_glob]
  }
}

resource "aws_iam_policy" "boundary" {
  name        = local.boundary_name
  description = "Permissions boundary for the ${local.prefix} Lambda roles"
  policy      = data.aws_iam_policy_document.boundary.json
}

data "aws_iam_policy_document" "deploy_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${local.sub_prefix}:environment:${var.environment}"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = "${local.prefix}-github-deploy"
  description          = "GitHub Actions (${var.github_repository}, environment ${var.environment}) deploys ${local.prefix}"
  assume_role_policy   = data.aws_iam_policy_document.deploy_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "deploy" {
  statement {
    sid       = "StateBucket"
    actions   = ["s3:ListBucket"]
    resources = [local.bucket_arn]
  }
  statement {
    sid       = "StateObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${local.bucket_arn}/${local.state_key}", "${local.bucket_arn}/${local.state_key}.tflock"]
  }
  statement {
    sid       = "RolesWithBoundary"
    actions   = ["iam:CreateRole", "iam:PutRolePolicy", "iam:PutRolePermissionsBoundary"]
    resources = [local.role_glob]
    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.boundary_arn]
    }
  }
  statement {
    sid = "ManageRoles"
    actions = [
      "iam:GetRole", "iam:UpdateRole", "iam:DeleteRole", "iam:TagRole", "iam:UntagRole", "iam:UpdateAssumeRolePolicy",
      "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:GetRolePolicy", "iam:DeleteRolePolicy",
      "iam:ListInstanceProfilesForRole", "iam:ListRoleTags",
    ]
    resources = [local.role_glob]
  }
  statement {
    sid       = "PassRoles"
    actions   = ["iam:PassRole"]
    resources = [local.role_glob]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com"]
    }
  }
  statement {
    sid       = "Lambda"
    actions   = ["lambda:*"]
    resources = ["arn:${local.partition}:lambda:${var.aws_region}:${local.account}:function:${local.prefix}-*"]
  }
  statement {
    sid       = "Table"
    actions   = ["dynamodb:*"]
    resources = [local.table_arn_glob]
  }
  statement {
    sid       = "HttpApi"
    actions   = ["apigateway:*"]
    resources = ["arn:${local.partition}:apigateway:${var.aws_region}::/apis", "arn:${local.partition}:apigateway:${var.aws_region}::/apis/*", "arn:${local.partition}:apigateway:${var.aws_region}::/tags/*"]
  }
  statement {
    sid     = "EventsLogsAlarms"
    actions = ["events:*", "logs:*", "cloudwatch:*"]
    resources = [
      "arn:${local.partition}:events:${var.aws_region}:${local.account}:rule/${local.prefix}-*",
      "arn:${local.partition}:logs:${var.aws_region}:${local.account}:log-group:/aws/lambda/${local.prefix}-*",
      local.alarm_arn_glob,
    ]
  }
  statement {
    sid       = "DescribeOnly"
    actions   = ["logs:DescribeLogGroups", "logs:ListTagsForResource", "cloudwatch:DescribeAlarms", "events:ListRules", "lambda:ListFunctions", "dynamodb:ListTables", "sts:GetCallerIdentity"]
    resources = ["*"]
  }
  statement {
    sid       = "DenyCiRolesAndBoundary"
    effect    = "Deny"
    actions   = ["iam:*"]
    resources = [local.ci_role_glob, local.boundary_arn]
  }
  statement {
    sid       = "DenyBoundaryRemoval"
    effect    = "Deny"
    actions   = ["iam:DeleteRolePermissionsBoundary", "iam:CreatePolicyVersion", "iam:SetDefaultPolicyVersion"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "deploy-${local.prefix}"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}

data "aws_iam_policy_document" "plan_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${local.sub_prefix}:pull_request"]
    }
  }
}

resource "aws_iam_role" "plan" {
  name                 = "${local.prefix}-github-plan"
  description          = "Pull requests in ${var.github_repository} run a read-only terraform plan"
  assume_role_policy   = data.aws_iam_policy_document.plan_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "plan" {
  # Pull-request plans run code from the PR branch, so this role reads only
  # this app's own resources. Plans use -lock=false: no write access to state.
  statement {
    sid       = "StateRead"
    actions   = ["s3:ListBucket"]
    resources = [local.bucket_arn]
  }
  statement {
    sid       = "StateObject"
    actions   = ["s3:GetObject"]
    resources = ["${local.bucket_arn}/${local.state_key}"]
  }
  statement {
    sid       = "IamRoles"
    actions   = ["iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListRoleTags"]
    resources = [local.role_glob]
  }
  statement {
    sid       = "IamBoundary"
    actions   = ["iam:GetPolicy", "iam:GetPolicyVersion"]
    resources = [local.boundary_arn]
  }
  statement {
    sid = "LambdaRead"
    actions = [
      "lambda:GetFunction", "lambda:GetFunctionConfiguration", "lambda:GetPolicy", "lambda:ListVersionsByFunction",
      "lambda:GetFunctionCodeSigningConfig", "lambda:GetFunctionEventInvokeConfig", "lambda:GetFunctionConcurrency",
      "lambda:ListTags", "lambda:GetRuntimeManagementConfig", "lambda:GetFunctionRecursionConfig",
    ]
    resources = ["arn:${local.partition}:lambda:${var.aws_region}:${local.account}:function:${local.prefix}-*"]
  }
  statement {
    sid = "DynamoDbRead"
    actions = [
      "dynamodb:DescribeTable", "dynamodb:DescribeContinuousBackups", "dynamodb:DescribeTimeToLive", "dynamodb:ListTagsOfResource",
      "dynamodb:DescribeKinesisStreamingDestination", "dynamodb:DescribeTableReplicaAutoScaling",
    ]
    resources = [local.table_arn_glob]
  }
  statement {
    sid     = "HttpApiRead"
    actions = ["apigateway:GET"]
    resources = [
      "arn:${local.partition}:apigateway:${var.aws_region}::/apis",
      "arn:${local.partition}:apigateway:${var.aws_region}::/apis/*",
      "arn:${local.partition}:apigateway:${var.aws_region}::/tags/*",
    ]
  }
  statement {
    sid       = "EventsRead"
    actions   = ["events:DescribeRule", "events:ListTargetsByRule", "events:ListTagsForResource"]
    resources = ["arn:${local.partition}:events:${var.aws_region}:${local.account}:rule/${local.prefix}-*"]
  }
  statement {
    sid       = "LogsRead"
    actions   = ["logs:ListTagsForResource", "logs:ListTagsLogGroup"]
    resources = ["arn:${local.partition}:logs:${var.aws_region}:${local.account}:log-group:/aws/lambda/${local.prefix}-*", "arn:${local.partition}:logs:${var.aws_region}:${local.account}:log-group:/aws/lambda/${local.prefix}-*:*"]
  }
  statement {
    sid       = "AlarmsRead"
    actions   = ["cloudwatch:ListTagsForResource"]
    resources = [local.alarm_arn_glob]
  }
  statement {
    sid       = "ListOnly"
    actions   = ["logs:DescribeLogGroups", "cloudwatch:DescribeAlarms", "sts:GetCallerIdentity"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "plan" {
  name   = "terraform-plan"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan.json
}

output "deploy_role_arn" {
  value = aws_iam_role.deploy.arn
}

output "plan_role_arn" {
  value = aws_iam_role.plan.arn
}

output "boundary_arn" {
  value = aws_iam_policy.boundary.arn
}

output "github_oidc_sub_prefix" {
  value = local.sub_prefix
}
