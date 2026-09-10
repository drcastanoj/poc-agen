"""
The only component in the serverless design that holds a GitHub token capable
of writing. Triggered by an EventBridge rule on ECS task state change
(infra/fargate/setup.sh); applies the patch the agent task left in S3,
commits, pushes, and opens the PR. See docs/lambda-migration.md §4.6 step 11 —
this Lambda existing at all, with its own narrow IAM role
(infra/fargate/iam/publish-role-policy.json: no bedrock, no lock table, no
deps cache, read-only on runs/*), is what turns the harness's guardrail from
the DENIED-command blocklist in agent.py into an IAM boundary: the agent task
that ran the model literally cannot reach a credential that can push.

Runs as a container-image Lambda (see lambda/publish/Dockerfile) because git
and gh are real binaries, not something a zip-based Lambda runtime ships.

Env:
  RUN_TABLE       DynamoDB table holding run state
  CACHE_BUCKET    S3 bucket holding runs/<id>/{patch.diff,meta.json}
  GH_TOKEN_PARAM  SSM parameter name for the write-scoped GitHub token
                  (default /poc/github-token-write)
"""
import json
import os
import subprocess
import boto3

RUN_TABLE = os.environ.get("RUN_TABLE", "poc-agent-runs")
CACHE_BUCKET = os.environ["CACHE_BUCKET"]
GH_TOKEN_PARAM = os.environ.get("GH_TOKEN_PARAM", "/poc/github-token-write")

s3 = boto3.client("s3")
ddb = boto3.client("dynamodb")
ssm = boto3.client("ssm")


def _run(cmd, cwd=None, env=None, check=True):
    return subprocess.run(
        cmd, cwd=cwd, env=env, check=check,
        capture_output=True, text=True, timeout=120,
    )


def _run_id_from_event(event):
    for override in event.get("detail", {}).get("overrides", {}).get("containerOverrides", []):
        for kv in override.get("environment", []):
            if kv.get("name") == "RUN_ID":
                return kv.get("value")
    return None


def _mark(run_id, **fields):
    names = {f"#{k}": k for k in fields}
    values = {f":{k}": {"S": str(v)} for k, v in fields.items()}
    ddb.update_item(
        TableName=RUN_TABLE,
        Key={"id": {"S": run_id}},
        UpdateExpression="SET " + ", ".join(f"{n} = :{n[1:]}" for n in names),
        ExpressionAttributeNames=names,
        ExpressionAttributeValues=values,
    )


def handler(event, _context):
    run_id = _run_id_from_event(event)
    if not run_id:
        print("no RUN_ID on this task state change event — ignoring")
        return {"skipped": "no run id"}

    item = ddb.get_item(TableName=RUN_TABLE, Key={"id": {"S": run_id}}).get("Item")
    if not item or item.get("state", {}).get("S") != "awaiting_publish":
        # Either not our run, or the agent task itself already reported a
        # terminal state (failed / error) before it ever reached the deferred
        # handoff — nothing for this Lambda to do either way.
        print(f"run {run_id}: state is not awaiting_publish — nothing to publish")
        return {"skipped": "not awaiting publish"}

    meta = json.loads(s3.get_object(Bucket=CACHE_BUCKET, Key=f"runs/{run_id}/meta.json")["Body"].read())
    patch_path = f"/tmp/{run_id}.diff"
    s3.download_file(CACHE_BUCKET, f"runs/{run_id}/patch.diff", patch_path)

    token = ssm.get_parameter(Name=GH_TOKEN_PARAM, WithDecryption=True)["Parameter"]["Value"]
    org, repo, ticket, task = meta["org"], meta["repo"], meta["ticket"], meta["task"]
    branch, base_branch, summary = meta["branch"], meta["base_branch"], meta["summary"]
    checks = meta.get("checks", {})

    repo_dir = f"/tmp/{run_id}-repo"
    env = {**os.environ, "GH_TOKEN": token, "HOME": "/tmp"}
    try:
        _run(["git", "config", "--global", "user.name", "akai-agent"], env=env)
        _run(["git", "config", "--global", "user.email", "akai-agent@deel.com"], env=env)
        # Shallow and scoped to the base branch — this Lambda only ever needs
        # a clean base to apply one small patch to, not the full mirror the
        # agent task worked from.
        _run([
            "git", "clone", "--quiet", "--depth", "1", "--branch", base_branch,
            f"https://x-access-token:{token}@github.com/{org}/{repo}.git", repo_dir,
        ], env=env)
        _run(["git", "switch", "--quiet", "-c", branch], cwd=repo_dir, env=env)
        _run(["git", "apply", "--binary", patch_path], cwd=repo_dir, env=env)
        _run(["git", "add", "-A"], cwd=repo_dir, env=env)
        _run(["git", "commit", "--quiet", "-m", f"feat: {task}", "-m", ticket], cwd=repo_dir, env=env)
        _run(["git", "push", "--quiet", "origin", f"refs/heads/{branch}:refs/heads/{branch}"],
             cwd=repo_dir, env=env)

        body = (
            f"## Summary\n\n{summary}\n\n## Validation\n\n"
            "All checks run in an isolated sandbox before this PR was opened:\n\n"
            "| Check | Result |\n|---|---|\n"
            f"| `{checks.get('lint', '')}` | pass |\n"
            f"| `{checks.get('typecheck', '')}` | pass |\n"
            f"| `{checks.get('test', '')}` | pass |\n"
            f"| `{checks.get('build', '')}` | pass |\n\n"
            "## Notes\n\n"
            f"Generated by the Akai coding agent (run `{run_id}`). Needs human review before merge.\n\n"
            f"{ticket}\n"
        )
        pr = _run([
            "gh", "pr", "create",
            "--repo", f"{org}/{repo}", "--base", base_branch, "--head", branch,
            "--title", f"{ticket}: {task}", "--body", body,
        ], cwd=repo_dir, env=env)
        pr_url = pr.stdout.strip()
        _mark(run_id, state="passed", phase="pull request opened", prUrl=pr_url)
        print(f"run {run_id}: opened {pr_url}")
        return {"prUrl": pr_url}

    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or exc.stdout or str(exc))[:2000]
        print(f"run {run_id}: publish failed: {detail}")
        _mark(run_id, state="failed", phase=f"publish failed: {detail[:200]}")
        raise
