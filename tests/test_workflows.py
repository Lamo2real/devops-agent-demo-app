"""The GitHub Actions workflows and setup script must agree with each other.
A YAML typo or a wrong check name only shows up on GitHub otherwise."""

import re
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent


def load(name):
    return yaml.safe_load((ROOT / ".github" / "workflows" / name).read_text())


def test_ci_and_deploy_parse():
    assert set(load("ci.yml")["jobs"]) == {"test", "plan"}
    assert set(load("deploy.yml")["jobs"]) == {"deploy", "pages"}


def test_ruleset_requires_the_real_ci_job_name():
    required = re.search(r'"required_status_checks": \[\{"context": "([^"]+)"\}\]', (ROOT / "scripts/github_setup.sh").read_text())
    assert required, "ruleset must require a status check"
    assert required.group(1) == load("ci.yml")["jobs"]["test"]["name"], "a wrong name would block every merge"


def test_pull_requests_cannot_deploy():
    ci = load("ci.yml")
    assert "pull_request" in ci[True]  # PyYAML reads the key `on` as True
    assert ci["permissions"] == {"contents": "read"}
    assert ci["jobs"]["plan"]["permissions"]["id-token"] == "write"
    assert "github.event.pull_request.head.repo.full_name == github.repository" in ci["jobs"]["plan"]["if"], "fork PRs must not get OIDC"
    assert "scripts/terraform.sh plan" in str(ci["jobs"]["plan"]["steps"])
    assert "apply" not in str(ci["jobs"]["plan"]["steps"])


def test_deploy_only_from_main_with_the_pinned_environment():
    deploy = load("deploy.yml")
    assert deploy[True]["push"]["branches"] == ["main"]
    job = deploy["jobs"]["deploy"]
    assert "github.ref_name == 'main'" in job["if"]
    assert job["environment"] == "${{ vars.ENVIRONMENT }}"  # the deploy role trusts this environment
    assert job["permissions"]["id-token"] == "write"
    steps = [s.get("name", "") for s in job["steps"]]
    assert steps.index("Tests") < steps.index("Deploy") < steps.index("Smoke test")


def test_pages_publishes_after_a_successful_deploy_with_the_api_url():
    deploy = load("deploy.yml")
    pages = deploy["jobs"]["pages"]
    assert pages["needs"] == "deploy"
    assert pages["permissions"] == {"contents": "read", "pages": "write", "id-token": "write"}
    assert deploy["jobs"]["deploy"]["outputs"]["api_url"] == "${{ steps.api.outputs.url }}"
    config_step = next(s for s in pages["steps"] if "config.js" in s.get("run", ""))
    assert config_step["env"]["API_URL"] == "${{ needs.deploy.outputs.api_url }}"
    assert "${{" not in config_step["run"], "values reach the shell through env, never inline"
    assert ".github.io" in (ROOT / "scripts/terraform.sh").read_text()


def test_every_workflow_action_is_a_known_publisher():
    allowed = ("actions/", "aws-actions/", "hashicorp/", "astral-sh/")
    for name in ("ci.yml", "deploy.yml"):
        for job in load(name)["jobs"].values():
            for step in job["steps"]:
                if "uses" in step:
                    assert step["uses"].startswith(allowed), step["uses"]
