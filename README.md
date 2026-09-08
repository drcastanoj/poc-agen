# Coder agent POC — Amazon Bedrock

An AI agent that implements a change in a real repository, verifies it in an
isolated container, and opens a pull request. Inference runs through Bedrock, so
nothing leaves your AWS account.

One EC2 instance. No Kubernetes, no CI service, no control plane.

```
agent/
  agent.py            the Bedrock Converse tool-use loop
  run-agent.sh        clone, install, agent, validation gate, PR
  AGENT_RULES.md      operating constraints for the agent
  Dockerfile          Node 20 + pnpm + python/boto3 + gh
  docker-compose.yml  agent + Postgres + Redis sidecars
  requirements.txt
server/
  index.js            demo console: queues runs, streams logs
  public/index.html
infra/
  ec2-userdata.sh
  instance-role-policy.json
scripts/
  parallel-smoke.sh   fires a matrix of runs at the console at once
cache/                persistent, gitignored (created on the instance)
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
