#!/usr/bin/env bash
# One-time setup by an administrator: permissions boundary + GitHub OIDC roles.
# Needs AWS credentials for the account (AWS_PROFILE works, also MFA/assume-role)
# and these variables (see README.md):
#   AWS_ACCOUNT_ID  AWS_REGION  STATE_BUCKET  GITHUB_REPOSITORY (owner/repo)
# Optional: APP_NAME (starfall), ENVIRONMENT (lab), AUTO_APPROVE=1
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${AWS_ACCOUNT_ID:?set AWS_ACCOUNT_ID}" "${AWS_REGION:?set AWS_REGION}" "${STATE_BUCKET:?set STATE_BUCKET}" "${GITHUB_REPOSITORY:?set GITHUB_REPOSITORY}"
APP_NAME="${APP_NAME:-starfall}"; ENVIRONMENT="${ENVIRONMENT:-lab}"

# An explicit profile wins over leftover keys; export a plain session for Terraform.
if [[ -n "${AWS_PROFILE:-}" ]]; then
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_CREDENTIAL_EXPIRATION
  eval "$(aws configure export-credentials --profile "$AWS_PROFILE" --format env)"
  unset AWS_PROFILE
fi
actual="$(aws sts get-caller-identity --query Account --output text)"
[[ "$actual" == "$AWS_ACCOUNT_ID" ]] || { echo "error: credentials are for account $actual, expected $AWS_ACCOUNT_ID" >&2; exit 1; }

# The roles must trust the exact OIDC "sub" GitHub sends (immutable subjects include ids).
sub_prefix="$(gh api "repos/$GITHUB_REPOSITORY/actions/oidc/customization/sub" \
  --jq 'if .use_default == false then "CUSTOM" else (.sub_claim_prefix // "") end' 2>/dev/null || true)"
[[ "$sub_prefix" == "CUSTOM" ]] && { echo "error: custom OIDC subject template; restore the default" >&2; exit 1; }
[[ -n "$sub_prefix" ]] || sub_prefix="repo:$GITHUB_REPOSITORY"
echo "==> GitHub OIDC subject prefix: $sub_prefix" >&2

DIR="$ROOT/terraform/bootstrap"
terraform -chdir="$DIR" init -input=false -reconfigure \
  -backend-config="bucket=$STATE_BUCKET" -backend-config="key=demo-app-bootstrap/$APP_NAME-$ENVIRONMENT.tfstate" \
  -backend-config="region=$AWS_REGION" -backend-config="encrypt=true" -backend-config="use_lockfile=true"
terraform -chdir="$DIR" apply -input=false ${AUTO_APPROVE:+-auto-approve} \
  -var="app_name=$APP_NAME" -var="environment=$ENVIRONMENT" -var="aws_account_id=$AWS_ACCOUNT_ID" \
  -var="aws_region=$AWS_REGION" -var="state_bucket_name=$STATE_BUCKET" \
  -var="github_repository=$GITHUB_REPOSITORY" -var="github_oidc_sub_prefix=$sub_prefix" \
  -var="alarm_prefix=${ALARM_PREFIX:-symptom-}"
echo "==> deploy role: $(terraform -chdir="$DIR" output -raw deploy_role_arn)" >&2
echo "==> plan role:   $(terraform -chdir="$DIR" output -raw plan_role_arn)" >&2
