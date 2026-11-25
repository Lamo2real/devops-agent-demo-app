# Starfall Dodge backend: API Gateway HTTP API -> Lambda -> DynamoDB (leaderboard),
# with symptom alarms that start AWS DevOps Agent investigations and a
# synthetic player that keeps traffic flowing.

data "aws_partition" "current" {}

data "archive_file" "app" {
  type        = "zip"
  source_dir  = "${path.module}/../../src"
  output_path = "${path.module}/.build/app.zip"
  excludes    = ["**/__pycache__/**", "**/*.pyc"]
}

locals {
  prefix       = "${var.app_name}-${var.environment}"
  partition    = data.aws_partition.current.partition
  boundary_arn = "arn:${local.partition}:iam::${var.aws_account_id}:policy/${local.prefix}-boundary"
  runtime      = "python3.13"
  api_name     = "${local.prefix}-api"
  traffic_name = "${local.prefix}-traffic"
}

# --- Data ----------------------------------------------------------------------------

resource "aws_dynamodb_table" "scores" {
  name         = "${local.prefix}-scores"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "board"
  range_key    = "sort_key"

  attribute {
    name = "board"
    type = "S"
  }
  attribute {
    name = "sort_key"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }
  server_side_encryption {
    enabled = true
  }
}

# --- API Lambda ------------------------------------------------------------------------

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.aws_account_id]
    }
  }
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/lambda/${local.api_name}"
  retention_in_days = 30
}

resource "aws_iam_role" "api" {
  name                 = "${local.prefix}-fn-api"
  assume_role_policy   = data.aws_iam_policy_document.lambda_trust.json
  permissions_boundary = local.boundary_arn
}

data "aws_iam_policy_document" "api" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.api.arn}:*"]
  }
  statement {
    actions   = ["dynamodb:PutItem", "dynamodb:Query"]
    resources = [aws_dynamodb_table.scores.arn]
  }
}

resource "aws_iam_role_policy" "api" {
  name   = "api"
  role   = aws_iam_role.api.id
  policy = data.aws_iam_policy_document.api.json
}

resource "aws_lambda_function" "api" {
  function_name    = local.api_name
  description      = "Starfall Dodge leaderboard API (${var.app_version})"
  role             = aws_iam_role.api.arn
  runtime          = local.runtime
  architectures    = ["arm64"]
  handler          = "starfall_api.handler.handler"
  filename         = data.archive_file.app.output_path
  source_code_hash = data.archive_file.app.output_base64sha256
  timeout          = 10
  memory_size      = 256

  environment {
    variables = {
      TABLE_NAME  = aws_dynamodb_table.scores.name
      APP_VERSION = var.app_version
      LOG_LEVEL   = "INFO"
    }
  }

  depends_on = [aws_iam_role_policy.api, aws_cloudwatch_log_group.api]
}

# --- HTTP API ----------------------------------------------------------------------------

resource "aws_apigatewayv2_api" "api" {
  name          = local.api_name
  protocol_type = "HTTP"

  # The game runs in the browser on another origin (GitHub Pages).
  cors_configuration {
    allow_origins = var.web_origins
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["content-type"]
    max_age       = 3600
  }
}

resource "aws_apigatewayv2_integration" "api" {
  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api.invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 12000
}

resource "aws_apigatewayv2_route" "routes" {
  for_each  = toset(["GET /health", "POST /scores", "GET /leaderboard"])
  api_id    = aws_apigatewayv2_api.api.id
  route_key = each.value
  target    = "integrations/${aws_apigatewayv2_integration.api.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.api.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 50
    throttling_rate_limit  = 25
  }

  depends_on = [aws_apigatewayv2_route.routes]
}

resource "aws_lambda_permission" "api" {
  statement_id  = "AllowHttpApi"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}

# --- Synthetic traffic -------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "traffic" {
  count             = var.traffic_enabled ? 1 : 0
  name              = "/aws/lambda/${local.traffic_name}"
  retention_in_days = 14
}

resource "aws_iam_role" "traffic" {
  count                = var.traffic_enabled ? 1 : 0
  name                 = "${local.prefix}-fn-traffic"
  assume_role_policy   = data.aws_iam_policy_document.lambda_trust.json
  permissions_boundary = local.boundary_arn
}

data "aws_iam_policy_document" "traffic" {
  count = var.traffic_enabled ? 1 : 0
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.traffic[0].arn}:*"]
  }
}

resource "aws_iam_role_policy" "traffic" {
  count  = var.traffic_enabled ? 1 : 0
  name   = "traffic"
  role   = aws_iam_role.traffic[0].id
  policy = data.aws_iam_policy_document.traffic[0].json
}

resource "aws_lambda_function" "traffic" {
  count            = var.traffic_enabled ? 1 : 0
  function_name    = local.traffic_name
  description      = "Synthetic player journey against the Starfall Dodge API"
  role             = aws_iam_role.traffic[0].arn
  runtime          = local.runtime
  architectures    = ["arm64"]
  handler          = "starfall_api.traffic.handler"
  filename         = data.archive_file.app.output_path
  source_code_hash = data.archive_file.app.output_base64sha256
  timeout          = 30
  memory_size      = 128

  environment {
    variables = {
      API_URL   = aws_apigatewayv2_api.api.api_endpoint
      LOG_LEVEL = "INFO"
    }
  }

  depends_on = [aws_iam_role_policy.traffic, aws_cloudwatch_log_group.traffic, aws_apigatewayv2_stage.default]
}

resource "aws_cloudwatch_event_rule" "traffic" {
  count               = var.traffic_enabled ? 1 : 0
  name                = "${local.prefix}-traffic"
  description         = "One synthetic player journey per minute"
  schedule_expression = "rate(1 minute)"
}

resource "aws_cloudwatch_event_target" "traffic" {
  count = var.traffic_enabled ? 1 : 0
  rule  = aws_cloudwatch_event_rule.traffic[0].name
  arn   = aws_lambda_function.traffic[0].arn
}

resource "aws_lambda_permission" "traffic" {
  count         = var.traffic_enabled ? 1 : 0
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.traffic[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.traffic[0].arn
}

# --- Symptom alarms (start AWS DevOps Agent investigations) -----------------------------------
# Names start with var.alarm_prefix. Each alarm needs 3 consecutive bad minutes
# (flap-safe: one alarm per problem, not per state change).

resource "aws_cloudwatch_metric_alarm" "http_5xx" {
  alarm_name          = "${var.alarm_prefix}${local.prefix}-http-5xx"
  alarm_description   = "The leaderboard API returns server errors (HTTP 5xx) to players for 3 minutes in a row. Service: ${local.api_name}. Logs: /aws/lambda/${local.api_name}."
  namespace           = "AWS/ApiGateway"
  metric_name         = "5xx"
  dimensions          = { ApiId = aws_apigatewayv2_api.api.id }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${var.alarm_prefix}${local.prefix}-function-errors"
  alarm_description   = "The leaderboard API Lambda throws errors for 3 minutes in a row. Function: ${local.api_name}."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.api.function_name }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
}

resource "aws_cloudwatch_metric_alarm" "latency" {
  alarm_name          = "${var.alarm_prefix}${local.prefix}-slow-responses"
  alarm_description   = "Leaderboard API p95 latency above 2 seconds for 5 of 5 minutes. Service: ${local.api_name}."
  namespace           = "AWS/ApiGateway"
  metric_name         = "Latency"
  dimensions          = { ApiId = aws_apigatewayv2_api.api.id }
  extended_statistic  = "p95"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  threshold           = 2000
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
}

output "api_url" {
  description = "Base URL of the leaderboard API (the game page calls it)."
  value       = aws_apigatewayv2_api.api.api_endpoint
}

output "api_function" {
  value = aws_lambda_function.api.function_name
}

output "alarm_names" {
  value = [
    aws_cloudwatch_metric_alarm.http_5xx.alarm_name,
    aws_cloudwatch_metric_alarm.lambda_errors.alarm_name,
    aws_cloudwatch_metric_alarm.latency.alarm_name,
  ]
}
