# Starfall Dodge: a game maintained with AWS DevOps Agent

An original browser arcade game with an online leaderboard, built to show AWS DevOps
Agent working on a real service: investigating alarms, finding the commit that broke
production, reviewing pull requests and proposing fixes. The agent itself is set up by
the sibling repository `devops-agent`.

**How you play:** dodge the falling meteors, catch the crystals (each is worth 10 x your
combo, up to x5, and a hit resets it), three lives. Arrow keys or A / D, or drag on a phone.

```
player's browser (game on GitHub Pages)
        │  POST /scores, GET /leaderboard
        ▼
API Gateway ─► Lambda (starfall_api) ─► DynamoDB          synthetic players (every minute) ─┘
                                 │
        CloudWatch alarms "symptom-starfall-lab-*" ─► AWS DevOps Agent investigates
        GitHub: this repo (code, commits, deploy runs, PRs) ◄── agent reads and reviews
```

## Branch model

`main` is production. Work on a feature branch and open a pull request: it runs the tests
(Python, Terraform, game rules) and a read-only `terraform plan`. Merging to `main` deploys:
tests, Terraform apply, smoke test (health, submit, leaderboard, validation, CORS), and then
the game is published on GitHub Pages with the API URL filled in. A ruleset blocks direct
pushes to `main`.

## Setup (once)

Needs: Terraform 1.10+, Python 3.13, Node 20+, AWS CLI, `gh`, admin credentials for the
account for one step, and the Terraform state bucket of the `devops-agent` template.

```bash
export AWS_ACCOUNT_ID=<account> AWS_REGION=eu-north-1
export STATE_BUCKET=<bucket from the devops-agent bootstrap>
export GITHUB_REPOSITORY=<owner>/devops-agent-demo-app
AWS_PROFILE=<admin profile> scripts/bootstrap.sh   # the one admin step: boundary + GitHub OIDC roles
scripts/github_setup.sh                            # environment, variables, Pages, branch ruleset
```

Then merge a pull request: the first deploy creates the API and publishes the game at
`https://<owner>.github.io/devops-agent-demo-app/`.

## Security model

- The deploy role trusts only jobs in the GitHub environment `lab`, which accepts only
  `main`. Pull requests use a separate read-only plan role limited to this app's resources.
- The deploy role can create IAM roles only with the permissions boundary
  `starfall-lab-boundary` (log writes and two DynamoDB actions), and cannot change the CI
  roles or the boundary.
- No AWS keys are stored in GitHub; account details live in repository variables.
- The API is public by design (a game). Input is validated strictly, scores must be
  plausible, API Gateway throttles requests, and the page renders names as text only.

## Break it (the demo)

1. Make sure the agent is connected to this repository (see the `devops-agent` repo).
2. On a branch, break something realistic, for example in `src/starfall_api/handler.py`
   change the sort key so `put_item` writes a wrong attribute name, adjust the fake table in
   the test so the tests still pass, open a pull request and merge it.
3. The synthetic players fail within a minute. After 3 minutes the alarm
   `symptom-starfall-lab-http-5xx` fires and an investigation starts.
4. Expected: the agent names the merge commit, the file and the line, and proposes a fix.
5. Fix forward with a pull request (or revert), and close the investigation.

## Local development

```bash
make test                          # Python, Terraform and game-rule tests
cd web && python3 -m http.server 8080   # play offline at http://localhost:8080
```
