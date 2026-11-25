# Starfall Dodge: instructions for AWS DevOps Agent

This file describes the service so investigations and code reviews start with
the right context.

## What this service is

Starfall Dodge is a browser arcade game. Players dodge meteors and collect
crystals, then submit their score to a global leaderboard. The game is a static
page on GitHub Pages; this repository also holds its backend: an HTTP API
(API Gateway HTTP API, one Lambda function, one DynamoDB table) in eu-north-1.

| Route | Purpose |
| --- | --- |
| `GET /health` | Liveness; returns the deployed git commit in `version` |
| `POST /scores` | Submit a finished game: `player`, `score`, `duration_ms` |
| `GET /leaderboard?limit=10` | Best scores first (`board=synthetic` for test data) |

## Where things are

- API code: `src/starfall_api/handler.py`; synthetic players: `src/starfall_api/traffic.py` (once per minute)
- Game: `web/game.js` (rules, tested in Node), `web/app.js` (drawing, controls, API calls)
- Infrastructure: `terraform/main/main.tf`
- Deploy: GitHub Actions `deploy.yml`, on every merge to `main`: API first, then the game on Pages.
  The deployed commit is shown by `GET /health` (`version`) and in the Lambda description.
- Logs: CloudWatch log group `/aws/lambda/starfall-lab-api`. One JSON line per
  request: `route`, `status`, `latency_ms`, `request_id`. Unhandled exceptions
  are logged as `unhandled error` with a stack trace.
- Table: DynamoDB `starfall-lab-scores`, key `board` + `sort_key`. The sort key
  is `(10^8 - score)#time#id`, so a query in ascending order returns the best score first.

## Business rules that bugs tend to break

- A score must be possible: at most 60 points per second of play plus 100 slack
  (`MAX_POINTS_PER_SECOND` in the handler). The game itself never exceeds about 45 per second,
  so a rejected real player usually means the game and API rules have drifted apart.
- Player names: 1 to 16 characters, letters, digits, space, `_ . -`.
- Boards: `global` (real players) and `synthetic` (traffic generator, smoke test). Synthetic
  scores must never appear on `global`.
- The API allows the game's origin (CORS, `web_origins` in Terraform). If players report that
  the leaderboard does not load but the API answers, check CORS first.

## Alarms that start investigations

All start with `symptom-starfall-lab-`:

- `-http-5xx`: API Gateway returns 5xx for 3 minutes in a row
- `-function-errors`: the Lambda throws for 3 minutes in a row
- `-slow-responses`: p95 latency above 2 s for 5 minutes

Synthetic players call the API every minute, so these alarms see traffic around the
clock. The most common cause of an incident is a recent deployment.

## How to investigate

1. Read the alarm and when it started.
2. Compare with recent merges and deploy runs in this repository: the commit that
   introduced the failure is usually within the previous hour.
3. Query the Lambda log group for errors grouped by message since the start time.
4. Check the DynamoDB table (throttling, errors) and API Gateway metrics.
5. Name the commit and the file and line that caused it.

## Rules

- Do not change AWS resources. Propose changes as a GitHub issue, or as a pull
  request from a branch, never as a direct push to `main`.
- `main` is protected: changes need a pull request with passing tests. A merge deploys to production.
- A fix must include a test that fails before the fix.
- Never include player names from logs or the table in issues or comments.
