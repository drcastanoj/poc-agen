# Coder agent POC — Amazon Bedrock

An AI agent that implements a change in a real repository, verifies it in an
isolated container, and opens a pull request. Inference runs through Bedrock, so
nothing leaves your AWS account.

Two ways to run it — the code is shared between them (`run-agent.sh` and
`agent.py` are the same either way):

- **One EC2 instance.** No Kubernetes, no CI service, no control plane. Steps
  1–7 below.
- **Serverless — Lambda control plane, Fargate worker, no EC2.** Zero idle
  cost, no box to patch, and the guardrail that stops the agent from pushing
  becomes an IAM boundary instead of a string blocklist. See
  [Serverless path](#serverless-path-lambda--fargate-no-ec2) and
  [`docs/lambda-migration.md`](docs/lambda-migration.md) for the full design
  and cost comparison. This is the recommended path for anything beyond a
  one-afternoon demo.

```
agent/
  agent.py            the Bedrock Converse tool-use loop
  run-agent.sh        clone, install, agent, validation gate, PR
  AGENT_RULES.md      operating constraints for the agent
  Dockerfile          Node 20 + pnpm + python/boto3 + gh + aws cli + zstd
  docker-compose.yml  agent + Postgres + Redis sidecars (EC2 path)
  lib/
    cache.sh          repo mirror + deps cache: fs (EC2) | s3 (serverless)
    lock.sh           per-repo lock: flock (EC2) | dynamodb (serverless)
    report.sh         coarse run state -> DynamoDB, for the serverless console
  requirements.txt
server/
  index.js            demo console: queues runs, streams logs (EC2 path)
  public/index.html    same page serves both paths — see config.js
infra/
  ec2-userdata.sh
  instance-role-policy.json
  fargate/            serverless path — see docs/lambda-migration.md
    setup.sh           provisions everything: S3, DynamoDB, SQS, IAM, ECS,
                        Lambda, API Gateway, EventBridge, the console
    task-definition.json
    build-images.sh, build-lambda-zips.sh, deploy-console.sh
    iam/               one narrow policy per role — see §4.6 step 11
lambda/                serverless path
  api/                 API Gateway handler: enqueue + poll run state/logs
  dispatcher/          SQS -> ecs:RunTask
  publish/             the only component holding a GitHub write token —
                        container-image Lambda (needs real git + gh)
scripts/
  parallel-smoke.sh   fires a matrix of runs at the console at once
cache/                persistent, gitignored (created on the instance; EC2 path)
  repos/<org>/<repo>.git    bare mirror, cloned once per repo
  worktrees/<repo>/<run>    one checkout per run
  locks/<org>__<repo>.lock  per-repo git lock
  pnpm-store/               shared package store
```

## How it works

`run-agent.sh` checks out the repo from a local mirror (see below), installs
dependencies, then hands control to
`agent.py`, which loops against Bedrock with five tools: `read_file`,
`list_files`, `edit_file`, `write_file`, `run_bash`. The agent explores, edits,
runs lint and tests, reads failures, and fixes them.

When the agent stops, **the harness re-runs all four validation commands
itself**. The PR is opened only if every one exits zero. This is the load-bearing
design decision: the agent cannot self-certify, and it cannot reach around the
gate because `git push`, `git commit` and `gh` are blocked in `run_bash`.

## Repo cache and parallel runs

A repo is cloned **once**. `run-agent.sh` looks for a bare mirror at
`cache/repos/<org>/<repo>.git`; if it is missing it creates one, and if it is
there it just `git fetch`es. Each run then gets its own `git worktree` off that
mirror instead of its own clone. Second and later runs of a repo skip the clone
entirely, and N concurrent runs share one object store rather than N copies of
it.

Three details make that safe to do from several runs at once:

| Problem | Fix |
|---|---|
| Two runs racing to create or fetch the same mirror; concurrent ref writes | One `flock` per repo, held only for the seconds of git bookkeeping — never across install, agent or validation |
| Two prompts on the same ticket sluggifying to the same branch name | Collision checked against the mirror **and** the remote inside the lock, then suffixed with the run id |
| Parallel test suites truncating each other's tables | `docker compose -p poc-<run-id>` — each run gets its own Postgres and Redis. Caches stay shared because they are bind mounts, not project-scoped volumes |

Upstream branches are fetched into `refs/remotes/origin/*`, leaving `refs/heads/*`
in the mirror for per-run branches only, so an agent's branch can never collide
with an upstream one.

The console runs at most `MAX_CONCURRENT` agents (default 2) and queues the rest,
because each one is an install plus a test suite plus two sidecars. Raise it when
you raise the instance size. `GET /api/capacity` reports the current split.

Worktrees are removed when a run ends. `DRY_RUN=1` (or `KEEP_WORKTREE=1`) leaves
one behind for inspection — the path is printed in the log.

## Scope note

Point this at a repository **you own**, not a Deel repository. Company source
plus a company-scoped token on a personal AWS account is a governance problem,
and it's the first thing a reviewer will raise. A synthetic repo proves the
mechanism just as well. Running against a real Deel repo is a later step, on
Deel infrastructure.

## Step 1 — Bedrock model access

One-time per AWS account, and everything else fails confusingly without it.

1. Bedrock console → pick your region (`us-east-1` is the safest default).
2. **Model access** → request access to the Claude models you want.
3. Complete the use-case form. Access is granted on submission.
4. Find an invocable model id. Newer Claude models are only reachable through
   cross-region inference profiles, so check both:

```bash
aws bedrock list-inference-profiles --region us-east-1 \
  --query "inferenceProfileSummaries[?contains(inferenceProfileId,'anthropic')].inferenceProfileId" \
  --output table

aws bedrock list-foundation-models --region us-east-1 \
  --query "modelSummaries[?contains(modelId,'anthropic')].modelId" --output table
```

Take an id from the output and export it as `BEDROCK_MODEL_ID`. If the profile
listing returns rows, prefer those — invoking a bare foundation-model id fails
for models that require a profile.

5. Confirm you can actually invoke it before building anything:

```bash
aws bedrock-runtime converse --region us-east-1 \
  --model-id "$BEDROCK_MODEL_ID" \
  --messages '[{"role":"user","content":[{"text":"reply with the word ready"}]}]'
```

If this errors, stop here. Every later failure will look like a code bug.

## Step 2 — GitHub token

Fine-grained PAT, scoped to the single demo repo, with Contents and Pull
requests write access. Then:

```bash
aws ssm put-parameter --name /poc/github-token --type SecureString \
  --value "github_pat_..." --region us-east-1
```

Never in user data, the AMI, the repo, or a committed env file.

## Step 3 — IAM role

```bash
aws iam create-role --role-name poc-coder-agent \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

aws iam put-role-policy --role-name poc-coder-agent \
  --policy-name poc-coder-agent-policy \
  --policy-document file://infra/instance-role-policy.json

aws iam create-instance-profile --instance-profile-name poc-coder-agent
aws iam add-role-to-instance-profile --instance-profile-name poc-coder-agent \
  --role-name poc-coder-agent
```

The policy grants `bedrock:InvokeModel`, `bedrock:InvokeModelWithResponseStream`,
and read on exactly one SSM parameter. Nothing else.

## Step 4 — launch the instance

- AMI: Amazon Linux 2023, x86_64 (`ami-081b0a6eac00b4f53` in `us-east-1`)
- Type: `t3.xlarge` (4 vCPU / 16 GB). `pnpm install` plus a Postgres container
  will thrash anything smaller.
- Storage: 60 GB gp3
- IAM instance profile: `poc-coder-agent`
- Security group: **no inbound rules at all** — no key pair either
- User data: `infra/ec2-userdata.sh`, with `POC_REPO_URL` edited first

```bash
aws ec2 run-instances \
  --image-id ami-081b0a6eac00b4f53 \
  --instance-type t3.xlarge \
  --security-group-ids <sg-id> \
  --iam-instance-profile Name=poc-coder-agent \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":60,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --user-data file://infra/ec2-userdata.sh \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=poc-coder-agent}]' \
  --query 'Instances[0].InstanceId' --output text
```

Reach the box over **SSM Session Manager**, not SSH. The instance role needs
`AmazonSSMManagedInstanceCore` attached alongside the inline policy:

```bash
aws iam attach-role-policy --role-name poc-coder-agent \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
brew install --cask session-manager-plugin
```

A shell, and the console tunnel:

```bash
aws ssm start-session --target <instance-id>

aws ssm start-session --target <instance-id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8080"],"localPortNumber":["8080"]}'
# then open http://localhost:8080
```

A box that spawns containers and holds a GitHub token has no business being
publicly reachable. SSM keeps the security group genuinely empty — no port 22,
no key pair, no public ingress — and it tunnels over 443, so it also works on
corporate networks that block outbound SSH. Wait for the agent to register
(`aws ssm describe-instance-information`) before the first connect.

## Step 5 — smoke test

```bash
aws ssm start-session --target <instance-id>
cd /opt/poc/agent
docker compose build

export AWS_REGION=us-east-1
export BEDROCK_MODEL_ID=<id from step 1>
export GITHUB_ORG=drcastanoj
export BASE_BRANCH=main
export POC_CACHE_DIR=/opt/poc/cache
export GH_TOKEN=$(aws ssm get-parameter --name /poc/github-token \
  --with-decryption --query Parameter.Value --output text --region us-east-1)

RUN_ID=smoke-1 DRY_RUN=1 docker compose -p poc-smoke-1 run --rm agent \
  demo-service POC-1 "Remove the Profile item from the sidebar navigation"
docker compose -p poc-smoke-1 down -v
```

`DRY_RUN=1` stops before push and leaves the worktree for inspection — the path
is in the log. Only drop it once a dry run produces a diff you'd have accepted
yourself.

`RUN_ID` and `-p` are what keep runs apart, so pass both by hand here; the
console sets them from its own run id. Run this twice and the second run logs
`cache hit` instead of `cache miss`. Tear the project down afterwards or its
Postgres and Redis stay up.

Container credentials: on EC2 the agent container reaches the instance metadata
service for the role. If boto3 reports no credentials, check that Docker isn't
blocking the link-local metadata address, or pass a short-lived
`AWS_CONTAINER_CREDENTIALS_FULL_URI`.

## Step 6 — parallel smoke test

The serial path never exercised the cache or the locking, so test it directly.
Tunnel the console, then fire five prompts across two repos at once:

```bash
sudo systemctl set-environment DRY_RUN=1
sudo systemctl restart poc-console      # no pushes, no PRs

CONSOLE=http://localhost:8080 ./scripts/parallel-smoke.sh my-repo-a my-repo-b
```

It posts the matrix back to back with no wait, tails every run's state until all
are terminal, then asserts on the captured output:

```
--- cache: expect exactly one mirror clone per repo ---
  my-repo-a        1 clone(s), 2 fetch(es)  [ok]
  my-repo-b        1 clone(s), 1 fetch(es)  [ok]

--- isolation: expect one distinct branch and worktree per run ---
  5 runs, 5 distinct branches, 5 distinct worktrees  [ok]
```

Two of the five prompts are deliberately identical, so they slug to the same
branch name — that is the collision case, and both should still get a branch.

What each result means:

- **more than one clone per repo** — the lock is not being taken, or
  `POC_CACHE_DIR` differs between the console and the container, so each run is
  looking at a different cache.
- **fewer distinct branches than runs** — the collision check is racing; two runs
  pushed to one branch.
- **fewer distinct worktrees than runs** — `RUN_ID` is not unique. The console
  passes its run id; check it is reaching the container.

Watch it work from the box while the matrix runs:

```bash
watch -n2 'docker ps --format "{{.Names}}\t{{.Status}}"; \
  ls /opt/poc/cache/worktrees/*/ 2>/dev/null'
```

You should see one agent container plus its own `postgres`/`redis` per active
run, at most `MAX_CONCURRENT` of them, and one worktree directory each. After
the last run finishes, `docker ps` is empty and the worktree directories are
gone; `cache/repos` keeps the mirrors.

## Step 7 — the console

Running as a systemd service:

```bash
systemctl status poc-console
journalctl -u poc-console -f
```

Open the tunnelled `http://localhost:8080`. The left rail shows the four
validation checks flipping from *not run* to *pass* or *fail*; the PR link
appears only when all four pass.

## Serverless path (Lambda + Fargate, no EC2)

Full design, the two options considered, and a cost comparison are in
[`docs/lambda-migration.md`](docs/lambda-migration.md). This section is just
"how to stand it up."

**What's different from the EC2 path**, concretely:

| | EC2 path | Serverless path |
|---|---|---|
| Compute | `docker compose run` on one instance | `ecs:RunTask` on Fargate (`infra/fargate/task-definition.json` — same three containers as `docker-compose.yml`: agent, postgres, redis) |
| Repo mirror + deps cache | bind-mounted `cache/` | S3 (`agent/lib/cache.sh`, `CACHE_BACKEND=s3`) |
| Per-repo lock | `flock` on that same mount | DynamoDB conditional writes with a TTL (`agent/lib/lock.sh`, `LOCK_BACKEND=dynamodb`) |
| Commit + push + PR | `run-agent.sh` does it inline | `run-agent.sh` stops after validation and hands a patch to S3 (`PUBLISH_MODE=deferred`); a separate Lambda (`lambda/publish`) applies it and opens the PR |
| Console | Express + SSE, systemd | static page (`deploy-console.sh`) polling `lambda/api`, which is stateless |
| The guardrail against a stray push | `DENIED` list in `agent.py` only | that list, **plus** the Fargate task's IAM role has no credential that can write to GitHub at all — see §4.6 step 11 of the migration doc |

Everything in `agent/agent.py` — the tool loop, the token/turn ceilings, the
`safe_path()` confinement — is unchanged. `run-agent.sh` is the same script
too; the serverless-only behavior is switched on entirely by environment
variables (`CACHE_BACKEND`, `LOCK_BACKEND`, `PUBLISH_MODE`), which default to
today's EC2 behavior when unset.

### Setup

Prerequisites: Docker running locally, `aws`/`node`/`npm`/`zip`/`jq` on
`PATH`, and credentials with room to create IAM roles, ECS/Lambda/API
Gateway/EventBridge resources.

```bash
export BEDROCK_MODEL_ID=<id from Step 1 above>
export GITHUB_ORG=drcastanoj
cd infra/fargate
./setup.sh
```

This provisions, in order: the S3 cache bucket, the two DynamoDB tables, an
SQS queue, five narrowly-scoped IAM roles (one per component — see `iam/`),
a public subnet + no-inbound security group (no NAT gateway — see the
migration doc §7.4 on why that's a deliberate $33/mo saved, not an oversight),
builds and pushes both container images, an ECS cluster and the task
definition, the two zip-based Lambdas plus the container-image publish
Lambda, the SQS-to-dispatcher wiring, an API Gateway HTTP API, the
EventBridge rule that fires `lambda/publish` when an agent task stops, and
the static console.

It does **not** create your GitHub tokens — same reasoning as Step 2 above,
sharpened by the split itself:

```bash
aws ssm put-parameter --name /poc/github-token-read --type SecureString \
  --value "github_pat_..." --region us-east-1
  # Contents:read only. This is the one the Fargate task's role can reach.

aws ssm put-parameter --name /poc/github-token-write --type SecureString \
  --value "github_pat_..." --region us-east-1
  # Contents:write + Pull requests:write. Only lambda/publish's role can
  # reach this parameter — see infra/fargate/iam/publish-role-policy.json.
```

Two fine-grained PATs on the same demo repo, differing only in scope, is the
whole point: even if `PUBLISH_MODE` were somehow set wrong, the Fargate
task's credential physically cannot push.

`setup.sh` prints the console URL and a `curl` smoke test at the end.
Re-running it is safe — it checks for each resource before creating it — but
it isn't fully idempotent under a partial failure; read what failed and
re-run rather than expecting every state to self-heal.

### Testing it

Six checks, each exercising one more layer than the last, so a failure points
at one place instead of "something in the pipeline." Set these once:

```bash
export AWS_REGION=us-east-1
export CLUSTER=poc-agent-cluster
API_BASE=https://<api-id>.execute-api.us-east-1.amazonaws.com   # setup.sh printed this
CACHE_BUCKET=poc-agent-cache-$(aws sts get-caller-identity --query Account --output text)
```

**1. Infra sanity** — confirm setup.sh actually created everything before
blaming the pipeline for a resource that was never there:

```bash
aws dynamodb describe-table --table-name poc-agent-runs --query Table.TableStatus
aws dynamodb describe-table --table-name poc-agent-locks --query Table.TableStatus
aws sqs get-queue-url --queue-name poc-agent-runs
aws ecs describe-task-definition --task-definition poc-agent-run --query 'taskDefinition.status'
aws lambda get-function --function-name poc-agent-api --query 'Configuration.State'
aws lambda get-function --function-name poc-agent-dispatcher --query 'Configuration.State'
aws lambda get-function --function-name poc-agent-publish --query 'Configuration.State'
aws ssm get-parameter --name /poc/github-token-read >/dev/null && echo "read token: set"
aws ssm get-parameter --name /poc/github-token-write >/dev/null && echo "write token: set"
```

**2. The Fargate task alone** — `ecs:RunTask` directly, bypassing the API and
dispatcher entirely. This is the equivalent of the EC2 path's Step 5: it
isolates the cache/lock/agent-loop layer from everything above it.

```bash
SUBNET_ID=$(aws ec2 describe-subnets --filters Name=default-for-az,Values=true \
  --query 'Subnets[0].SubnetId' --output text)
SG_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values=poc-agent-fargate \
  --query 'SecurityGroups[0].GroupId' --output text)

aws ecs run-task --cluster "$CLUSTER" --task-definition poc-agent-run --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_ID],securityGroups=[$SG_ID],assignPublicIp=ENABLED}" \
  --overrides '{"containerOverrides":[{"name":"agent",
    "command":["demo-service","POC-1","Remove the Profile item from the sidebar navigation"],
    "environment":[{"name":"RUN_ID","value":"manual-test-1"},{"name":"DRY_RUN","value":"1"}]}]}'
```

`DRY_RUN=1` stops before the S3 handoff, same meaning as on EC2. Tail it:

```bash
aws logs tail /ecs/poc-agent-run --since 1m --follow
```

Expect to see the same phase markers as the EC2 path (`cache miss`/`cache
hit`, `running agent`, `validating`, `PASS`/`FAIL` lines) plus, near the end,
`PUBLISH_MODE=deferred — writing patch instead of pushing` and `DRY_RUN=1 —
stopping before handoff`. If this step fails, the problem is in
`agent/lib/{cache,lock}.sh`, the task's IAM role, or networking — not in
anything Lambda.

**3. One real run through the whole pipeline** — same call
`scripts/parallel-smoke.sh` already knows how to make, so use it for the
capacity check before you even queue anything:

```bash
curl -s "$API_BASE/api/capacity"

RUN_ID=$(curl -s -X POST "$API_BASE/api/runs" -H 'content-type: application/json' \
  -d '{"repo":"demo-service","ticket":"POC-1","task":"Remove the Profile item from the sidebar navigation"}' \
  | jq -r .id)
echo "run: $RUN_ID"

watch -n2 "curl -s $API_BASE/api/runs/$RUN_ID | jq '{state,phase,checks,prUrl}'"
```

Expected state sequence: `queued` → `starting` → `coding` → `validating` →
`awaiting_publish` → `passed` (the last transition is `lambda/publish`, not
the Fargate task — see check 5). Confirm each hop against its own source
instead of only trusting the aggregate state:

```bash
# 3a. did the dispatcher actually launch a task and record it?
aws dynamodb get-item --table-name poc-agent-runs --key "{\"id\":{\"S\":\"$RUN_ID\"}}" \
  --query 'Item.{taskArn:taskArn,logStream:logStream}'

# 3b. the task's own log, same as check 2
aws logs tail /ecs/poc-agent-run --since 5m --filter-pattern "$RUN_ID" 2>/dev/null \
  || curl -s "$API_BASE/api/runs/$RUN_ID/log"

# 3c. did the patch actually land in S3?
aws s3 ls "s3://$CACHE_BUCKET/runs/$RUN_ID/"
```

**4. Publish alone** — once a run is sitting at `awaiting_publish` (or replay
one that already finished — `lambda/publish` re-reads the same S3 objects),
confirm the EventBridge → publish leg fired without waiting on step 3's timing:

```bash
aws logs tail /aws/lambda/poc-agent-publish --since 10m
aws events list-targets-by-rule --rule poc-agent-task-stopped
```

If the run sits at `awaiting_publish` indefinitely, the rule isn't matching —
check `detail.group` on the actual ECS task-stopped event
(`aws ecs describe-tasks --cluster "$CLUSTER" --tasks <taskArn> --query 'tasks[0].group'`
should read `family:poc-agent-run`) rather than assuming the Lambda itself is
broken.

**5. The IAM boundary is real, not just a comment** — the point of
`PUBLISH_MODE=deferred` is that the task role *cannot* push even if it tried.
Verify it directly instead of trusting the policy JSON by inspection:

```bash
aws iam simulate-principal-policy \
  --policy-source-arn arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/poc-agent-task-role \
  --action-names ssm:GetParameter \
  --resource-arns "arn:aws:ssm:${AWS_REGION}:$(aws sts get-caller-identity --query Account --output text):parameter/poc/github-token-write" \
  --query 'EvaluationResults[0].EvalDecision'
```

Expect `implicitDeny`. If this ever comes back `allowed`, stop — that's the
guardrail failing, not a test failing.

**6. A deliberately failing run** — same as the EC2 demo script's opening
beat. Point it at a task you know breaks a check (or a nonexistent function
name) and confirm the pipeline stops cleanly:

```bash
curl -s -X POST "$API_BASE/api/runs" -H 'content-type: application/json' \
  -d '{"repo":"demo-service","ticket":"POC-2","task":"Rename a function that does not exist to force a lint failure"}'
```

Expect state to land on `failed`, no `prUrl`, nothing in
`s3://$CACHE_BUCKET/runs/<id>/`, and no invocation of `lambda/publish` at all
(check 4's log tail should show nothing for this run — `report_failed` in
`agent/lib/report.sh` sets state before the deferred handoff is ever reached,
so publish never gets an `awaiting_publish` item to act on).

**7. Parallel + the console** — `scripts/parallel-smoke.sh` talks only to
`/api/capacity`, `/api/runs` and `/api/runs/:id/log`, all of which
`lambda/api` implements with the same shapes, so it runs unchanged:

```bash
CONSOLE="$API_BASE" ./scripts/parallel-smoke.sh demo-service demo-web
```

Same assertions as the EC2 path (one clone per repo, one branch and worktree
per run). Then open the console URL `deploy-console.sh` printed and submit a
run by hand — confirm the sidebar's phase/checks update roughly once a
second (it's polling now, not streaming, so expect a ~1s lag, not the EC2
path's push-the-instant-it-happens feel) and that the PR link appears only
once state reaches `passed`.

### Rerunning after a change

- Changed `agent/`, `agent/Dockerfile`, or anything `agent/lib/`: `./build-images.sh <account-id>` (rebuilds and pushes `poc-agent`, and the task definition already points at `:latest`, so the next `RunTask` picks it up — no re-registration needed).
- Changed `lambda/api` or `lambda/dispatcher`: `./build-lambda-zips.sh` then re-run `setup.sh` (it always calls `update-function-code`).
- Changed `lambda/publish`: `./build-images.sh <account-id>` then re-run `setup.sh`.
- Changed `server/public/index.html`: `./deploy-console.sh <site-bucket> <api-base>`.

## Guardrails already in place

| Guardrail | Where |
|---|---|
| File writes confined to the repo tree | `safe_path()` — rejects `../` and absolute escapes |
| `git push`, `git commit`, `gh`, `sudo`, `rm -rf /` blocked | `DENIED` list in `run_bash` |
| Round-trip cap | `MAX_ITERATIONS`, default 40 |
| Token ceiling | `MAX_TOKENS_TOTAL`, default 2M |
| Per-command timeout | `BASH_TIMEOUT`, default 900s |
| Tool output truncation | 6 KB per result, keeps head and tail |
| Independent validation | `run-agent.sh` re-runs all four checks after the agent exits |
| Token never persisted in the cache | Mirror remotes are token-free; auth via a 0600 credential file in the container |
| Concurrency ceiling | `MAX_CONCURRENT`, default 2 — the rest queue |
| Per-repo git lock | `flock` with `LOCK_TIMEOUT`, default 900s |
| **Serverless path only:** the guardrail as an IAM boundary, not just a blocklist | `PUBLISH_MODE=deferred` — the Fargate task's role has no GitHub credential capable of writing at all; only `lambda/publish`'s separate role can reach the write-scoped token |

## What to show in the demo

Open with the gate, not a success.

1. **A failing run.** Give it a task you know it'll get wrong, or break a test
   deliberately. Show `FAIL test` and no PR link. The claim being demonstrated
   is that wrong code doesn't reach GitHub.
2. **A passing run.** Four passes, PR link appears, validation table in the body.
3. **The diff.** Read it aloud. Whether a reviewer would merge it is the only
   question that matters, and it's a question about the diff.
4. **The real number.** Run five tasks beforehand and report how many produced a
   mergeable PR. Two or three out of five is a genuine result; one cherry-picked
   success invites the question you can't answer.

## Cost

| Item | Rough cost |
|---|---|
| `t3.xlarge` on demand | ~$0.166/hr, about $4/day if left running |
| 60 GB gp3 | ~$5/month |
| Bedrock tokens | a few dollars per run, task-dependent |

Set a billing alarm before your first run. An agent in a retry loop spends real
money, which is what `MAX_ITERATIONS` and `MAX_TOKENS_TOTAL` are for.

The serverless path's compute bill is a small fraction of this at POC volume —
often under $5/month — because nothing is running between runs. See
`docs/lambda-migration.md` §7 for the full breakdown, including the traps
(provisioned concurrency, a NAT gateway, EFS) that quietly recreate the
always-on instance's cost if you're not deliberate about avoiding them.

## Known gotchas

- **`AccessDeniedException` on invoke.** Either model access isn't granted, or
  `BEDROCK_MODEL_ID` is a foundation-model id for a model that requires an
  inference profile. Re-run step 1.
- **`ValidationException` about the model id.** Region mismatch — the profile
  and `AWS_REGION` must agree.
- **Tests need a seeded database.** Add the migration or seed command to
  `run-agent.sh` before the agent step, not to the agent's prompt.
- **The agent tries to commit.** It gets a BLOCKED message and continues. That's
  working as intended.
- **Runs are in memory.** Restarting the console loses history. Fine for a POC —
  say so rather than being asked. The repo cache on disk is unaffected.
- **`detected dubious ownership in repository`.** The cache is bind-mounted from
  the host, so its uid rarely matches the container's. `run-agent.sh` sets
  `safe.directory '*'`; if you invoke git against the cache by hand, do the same.
- **`docker compose` not found.** The instance gets the CLI plugin from user
  data. On a machine with only the standalone binary, run the console with
  `DOCKER_COMPOSE=docker-compose`.
- **A run waits a long time in `queued`.** Expected above `MAX_CONCURRENT`. If
  nothing is running either, a previous run's sidecars may still be up — check
  `docker ps` and `docker compose -p poc-<run-id> down -v`.
- **The cache grows.** One mirror per repo, plus the pnpm store. Neither is
  pruned automatically; `du -sh /opt/poc/cache/*` before blaming the agent.

## What this deliberately omits

Persistent run history, GitHub App auth, egress allowlisting, cache eviction, an
eval harness, and any scheduling smarter than one FIFO queue on one box. The
queue is in memory, so a console restart forgets what was waiting. Each matters
before this touches a real repository on shared infrastructure. None is needed to
answer the only question a POC exists to answer: can it write a pull request
someone would merge?
