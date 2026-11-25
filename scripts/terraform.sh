#!/usr/bin/env bash
# Run terraform for the main stack with the settings from environment variables
# (CI sets them from repository variables). Usage: scripts/terraform.sh plan|apply|destroy
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${AWS_ACCOUNT_ID:?}" "${AWS_REGION:?}" "${STATE_BUCKET:?}"
APP_NAME="${APP_NAME:-starfall}"; ENVIRONMENT="${ENVIRONMENT:-lab}"
DIR="$ROOT/terraform/main"
terraform -chdir="$DIR" init -input=false -reconfigure \
  -backend-config="bucket=$STATE_BUCKET" -backend-config="key=demo-app/$APP_NAME-$ENVIRONMENT.tfstate" \
  -backend-config="region=$AWS_REGION" -backend-config="encrypt=true" -backend-config="use_lockfile=true"
args=(-input=false -var="app_name=$APP_NAME" -var="environment=$ENVIRONMENT" -var="aws_account_id=$AWS_ACCOUNT_ID"
  -var="aws_region=$AWS_REGION" -var="alarm_prefix=${ALARM_PREFIX:-symptom-}" -var="app_version=${APP_VERSION:-${GITHUB_SHA:-dev}}")
# Browser origins that may call the API: the game on GitHub Pages, plus localhost.
# In GitHub Actions the Pages origin is https://<owner>.github.io (lowercase).
origin="${WEB_ORIGIN:-}"
if [[ -z "$origin" && -n "${GITHUB_REPOSITORY_OWNER:-}" ]]; then
  origin="https://$(tr '[:upper:]' '[:lower:]' <<< "$GITHUB_REPOSITORY_OWNER").github.io"
fi
if [[ -n "$origin" ]]; then args+=(-var="web_origins=[\"$origin\",\"http://localhost:8080\"]"); fi
case "${1:?plan|apply|destroy}" in
  plan)    terraform -chdir="$DIR" plan -lock=false "${args[@]}" ;;  # read-only role: no state writes
  apply)   terraform -chdir="$DIR" apply "${args[@]}" ${AUTO_APPROVE:+-auto-approve} ;;
  destroy) terraform -chdir="$DIR" destroy "${args[@]}" ${AUTO_APPROVE:+-auto-approve} ;;
  *) echo "usage: $0 plan|apply|destroy" >&2; exit 2 ;;
esac
