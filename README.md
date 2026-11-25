# Orders API: a demo app maintained with AWS DevOps Agent

A small Python API on AWS (API Gateway HTTP API, Lambda, DynamoDB), deployed with
Terraform and GitHub Actions through OIDC. It exists to show AWS DevOps Agent
working on a real service: investigating alarms, finding the commit that broke
production, reviewing pull requests and proposing fixes. The agent itself is
set up by the sibling repository `devops-agent` (alarm to investigation path).

```
customer traffic ─► API Gateway ─► Lambda (orders_api) ─► DynamoDB
synthetic traffic (every minute) ─┘             │
                                                ▼
        CloudWatch alarms "symptom-orders-api-lab-*" ─► AWS DevOps Agent investigates
                                                ▲
        GitHub: this repo (code, commits, deploy runs, PRs) ◄── agent reads and reviews
```

## Branch model

`main` is production. Work on a feature branch and open a pull request: it runs the
tests and a read-only `terraform plan`. Merging to `main` deploys (tests, apply, smoke test).
A ruleset blocks direct pushes to `main`.

## Setup (once)

Needs: Terraform 1.10+, Python 3.13, AWS CLI, `gh`, admin credentials for the account,
and the Terraform state bucket of the `devops-agent` template.

```bash
export AWS_ACCOUNT_ID=<account> AWS_REGION=eu-north-1
export STATE_BUCKET=<bucket from the devops-agent bootstrap>
export GITHUB_REPOSITORY=<owner>/devops-agent-demo-app
AWS_PROFILE=<admin profile> scripts/bootstrap.sh   # boundary + GitHub OIDC roles
scripts/github_setup.sh                            # environment, variables, branch ruleset
```

Then push a branch, open a pull request and merge it. The first deploy creates the API.

## Security model

- The deploy role trusts only jobs in the GitHub environment `lab`, which accepts only `main`.
  Pull requests use a separate read-only plan role.
- The deploy role can create IAM roles only with the permissions boundary
  `orders-api-lab-boundary` (log writes and two DynamoDB actions), and cannot change
  the CI roles or the boundary.
- No AWS keys are stored in GitHub; account details live in repository variables.

## Break it (the demo)

1. Make sure the agent is connected to this repository (see the `devops-agent` repo).
2. On a branch, break something realistic, for example in `src/orders_api/handler.py`
   change `table().put_item(...)` to use a wrong key name such as `order_id` -> `orderId`
   (DynamoDB rejects it), keep the tests passing by editing the fake table, open a
   pull request and merge it.
3. The synthetic customer fails within a minute. After 3 minutes the alarm
   `symptom-orders-api-lab-http-5xx` fires and an investigation starts.
4. Expected: the agent names the merge commit, the file and the line, and proposes a fix.
5. Fix forward with a pull request (or revert), and close the investigation.

## Local development

```bash
make test        # unit tests + Terraform fmt, validate and mock tests
```
