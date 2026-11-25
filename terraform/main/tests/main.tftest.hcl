mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}
mock_provider "archive" {}

variables {
  app_name       = "starfall"
  environment    = "lab"
  aws_account_id = "123456789012"
  aws_region     = "eu-north-1"
}

run "defaults" {
  command = plan
  assert {
    condition     = aws_iam_role.api.name == "starfall-lab-fn-api" && aws_iam_role.api.permissions_boundary == "arn:aws:iam::123456789012:policy/starfall-lab-boundary"
    error_message = "Lambda roles need the fn- prefix and the boundary (required by the deploy role)."
  }
  assert {
    condition     = startswith(aws_cloudwatch_metric_alarm.http_5xx.alarm_name, "symptom-") && startswith(aws_cloudwatch_metric_alarm.lambda_errors.alarm_name, "symptom-") && startswith(aws_cloudwatch_metric_alarm.latency.alarm_name, "symptom-")
    error_message = "Symptom alarms must start with the prefix that triggers the agent."
  }
  assert {
    condition     = aws_cloudwatch_metric_alarm.http_5xx.datapoints_to_alarm == 3 && aws_cloudwatch_metric_alarm.latency.datapoints_to_alarm == 5
    error_message = "Alarms must be flap-safe (several consecutive periods)."
  }
  assert {
    condition     = length(aws_lambda_function.traffic) == 1 && length(aws_cloudwatch_event_rule.traffic) == 1
    error_message = "Traffic generator is on by default."
  }
  assert {
    condition     = aws_apigatewayv2_api.api.protocol_type == "HTTP" && length(aws_apigatewayv2_route.routes) == 3
    error_message = "Three routes expected."
  }
  assert {
    condition     = aws_dynamodb_table.scores.hash_key == "board" && aws_dynamodb_table.scores.range_key == "sort_key"
    error_message = "Leaderboard keys must match the handler (board, sort_key)."
  }
  assert {
    condition     = aws_lambda_function.api.handler == "starfall_api.handler.handler" && aws_lambda_function.traffic[0].handler == "starfall_api.traffic.handler"
    error_message = "Handler paths must match the Python package."
  }
  assert {
    condition     = contains(toset(aws_apigatewayv2_api.api.cors_configuration[0].allow_origins), "http://localhost:8080")
    error_message = "CORS must allow the configured origins."
  }
}

run "no_traffic" {
  command = plan
  variables {
    traffic_enabled = false
  }
  assert {
    condition     = length(aws_lambda_function.traffic) == 0
    error_message = "Traffic generator must be optional."
  }
}

run "custom_prefix" {
  command = plan
  variables {
    alarm_prefix = "sev1-"
  }
  assert {
    condition     = startswith(aws_cloudwatch_metric_alarm.http_5xx.alarm_name, "sev1-")
    error_message = "Alarm prefix must be configurable."
  }
}

run "name_too_long" {
  command = plan
  variables {
    app_name    = "a-very-long-application-name-x"
    environment = "nonprod"
  }
  expect_failures = [var.environment]
}
