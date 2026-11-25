#!/usr/bin/env bash
# Connect this repository's GitHub Actions to the bootstrap roles (gh CLI, repo admin):
# environment <ENVIRONMENT> limited to main, repository variables, and a ruleset
# so main changes only through pull requests with passing tests.
set -euo pipefail
: "${AWS_ACCOUNT_ID:?}" "${AWS_REGION:?}" "${STATE_BUCKET:?}" "${GITHUB_REPOSITORY:?}"
APP_NAME="${APP_NAME:-orders-api}"; ENVIRONMENT="${ENVIRONMENT:-lab}"; BRANCH="${BRANCH:-main}"
repo="$GITHUB_REPOSITORY"; prefix="$APP_NAME-$ENVIRONMENT"

gh api -X PUT "repos/$repo/environments/$ENVIRONMENT" --input - >/dev/null <<JSON
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
JSON
existing="$(gh api "repos/$repo/environments/$ENVIRONMENT/deployment-branch-policies" --jq '.branch_policies[] | "\(.id) \(.name)"')"
while read -r id name; do
  [[ -z "${id:-}" || "$name" == "$BRANCH" ]] && continue
  gh api -X DELETE "repos/$repo/environments/$ENVIRONMENT/deployment-branch-policies/$id" >/dev/null
done <<< "$existing"
grep -q " $BRANCH$" <<< "$existing" || gh api -X POST "repos/$repo/environments/$ENVIRONMENT/deployment-branch-policies" -f name="$BRANCH" -f type=branch >/dev/null

gh variable set AWS_DEPLOY_ROLE_ARN --repo "$repo" --body "arn:aws:iam::$AWS_ACCOUNT_ID:role/$prefix-github-deploy"
gh variable set AWS_PLAN_ROLE_ARN   --repo "$repo" --body "arn:aws:iam::$AWS_ACCOUNT_ID:role/$prefix-github-plan"
gh variable set AWS_ACCOUNT_ID      --repo "$repo" --body "$AWS_ACCOUNT_ID"
gh variable set AWS_REGION          --repo "$repo" --body "$AWS_REGION"
gh variable set STATE_BUCKET        --repo "$repo" --body "$STATE_BUCKET"
gh variable set APP_NAME            --repo "$repo" --body "$APP_NAME"
gh variable set ENVIRONMENT         --repo "$repo" --body "$ENVIRONMENT"

body="$(cat <<JSON
{"name": "production-branch", "target": "branch", "enforcement": "active",
 "conditions": {"ref_name": {"include": ["refs/heads/$BRANCH"], "exclude": []}},
 "rules": [{"type": "deletion"}, {"type": "non_fast_forward"},
  {"type": "pull_request", "parameters": {"required_approving_review_count": 0, "dismiss_stale_reviews_on_push": true,
    "require_code_owner_review": false, "require_last_push_approval": false, "required_review_thread_resolution": false}},
  {"type": "required_status_checks", "parameters": {"strict_required_status_checks_policy": false,
    "required_status_checks": [{"context": "Tests"}]}}]}
JSON
)"
rid="$(gh api "repos/$repo/rulesets" --jq '.[] | select(.name == "production-branch") | .id')"
if [[ -n "$rid" ]]; then gh api -X PUT "repos/$repo/rulesets/$rid" --input - >/dev/null <<< "$body"
else gh api -X POST "repos/$repo/rulesets" --input - >/dev/null <<< "$body"; fi
echo "GitHub Actions connected: environment '$ENVIRONMENT' (branch $BRANCH only), variables set, ruleset 'production-branch' active." >&2
