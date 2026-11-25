# Orders API: instructions for AWS DevOps Agent

This file describes the service so investigations and code reviews start with
the right context.

## What this service is

A small HTTP API for orders. Public endpoint behind API Gateway (HTTP API),
one Lambda function, one DynamoDB table. Region eu-north-1.

| Route | Purpose |
| --- | --- |
| `GET /health` | Liveness; returns the deployed git commit in `version` |
| `POST /orders` | Create an order (validated; total is computed) |
| `GET /orders/{order_id}` | Read an order |

## Where things are

- Code: `src/orders_api/handler.py` (API), `src/orders_api/traffic.py` (synthetic customer, once per minute)
- Infrastructure: `terraform/main/main.tf`
- Deploy: GitHub Actions, `deploy.yml`, on every merge to `main`. The deployed
  commit is shown by `GET /health` (`version`) and in the Lambda description.
- Logs: CloudWatch log group `/aws/lambda/orders-api-lab-api`. One JSON line
  per request: `route`, `status`, `latency_ms`, `request_id`. Unhandled
  exceptions are logged with `unhandled error` and a stack trace.
- Table: DynamoDB `orders-api-lab-orders` (on demand, key `order_id`).

## Alarms that start investigations

All start with `symptom-orders-api-lab-`:

- `-http-5xx`: API Gateway returns 5xx for 3 minutes in a row
- `-function-errors`: the Lambda throws for 3 minutes in a row
- `-slow-responses`: p95 latency above 2 s for 5 minutes

A synthetic customer calls the API every minute, so these alarms see traffic
around the clock. The most common cause of an incident is a recent deployment.

## How to investigate

1. Read the alarm and when it started.
2. Compare with recent merges and deploy runs in this repository: the commit
   that introduced the failure is usually within the previous hour.
3. Query the Lambda log group for errors grouped by message since the start time.
4. Check the DynamoDB table (throttling, errors) and API Gateway metrics.
5. Name the commit and the file and line that caused it.

## Rules

- Do not change AWS resources. Propose changes as a GitHub issue, or as a pull
  request from a branch, never as a direct push to `main`.
- `main` is protected: changes need a pull request with passing tests. A merge
  deploys to production.
- A fix must include a unit test that fails before the fix.
- Never include customer data from logs (`customer_id` values) in issues or comments.
