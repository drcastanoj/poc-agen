# Migrating the coder agent off EC2 onto Lambda

Status: **Option B implemented.** `agent/lib/{cache,lock,report}.sh`,
`infra/fargate/`, and `lambda/{api,dispatcher,publish}/` are the working
implementation of the design below — run `infra/fargate/setup.sh` to stand it
up, or see the README's [Serverless
path](../README.md#serverless-path-lambda--fargate-no-ec2) section for the
short version. Option A (all-Lambda, §4) was deliberately not built — §6
recommends against it, and nothing here changed that conclusion. It's left in
place as the reasoning for why the chosen design looks the way it does, and
as the fallback if a future constraint makes Lambda-only a hard requirement.

## 1. What the current design actually depends on

Before arguing about Lambda, name what the box provides. Every row here is a
dependency `run-agent.sh` has today, and each one has to be answered by the
replacement or deliberately dropped.

| # | Dependency | Where it lives now | Why it exists |
|---|---|---|---|
| D1 | Unbounded wall clock | the process runs until it's done | agent loop is `MAX_TURNS=40` model round trips, each of which may run a test suite |
| D2 | ~15–60 GB of working disk | 60 GB gp3 | bare mirrors + `node_modules` per worktree + pnpm store |
| D3 | Persistent shared filesystem | `/opt/poc/cache` bind mount | `cache/repos` mirror is the whole point of the cache design |
| D4 | POSIX advisory locks | `flock` on `cache/locks/<org>__<repo>.lock` | serialises mirror create/fetch/worktree/push across runs |
| D5 | A Docker daemon | `docker compose -p poc-<run-id>` | per-run Postgres + Redis so parallel test suites don't truncate each other |
| D6 | Long-lived process for streaming | `poc-console` systemd unit, SSE over a port-forward | the demo *is* the live log |
| D7 | An in-memory FIFO queue + `MAX_CONCURRENT` | `server/index.js` | ceiling is the box, not the design |
| D8 | Interactive debugging | SSM Session Manager, `docker ps`, `watch` | how you actually diagnosed the cache and locking bugs |

Lambda answers D2, D3, D4, D7 cleanly. It answers D5 and D6 awkwardly. **It
does not answer D1 at all**, and D1 is the one that matters.

## 2. The two troubles, quantified

### Trouble 1 — time. 15 minutes, hard.

Lambda's maximum timeout is **900 seconds**. It is not raisable by quota
request; there is no extension, no heartbeat, no "still working" signal. At 900s
the sandbox is destroyed mid-syscall.

Your own defaults say the run does not fit:

```
BASH_TIMEOUT = 900   # a SINGLE agent bash command may run as long as
                     # Lambda's entire maximum lifetime
LOCK_TIMEOUT = 900   # waiting for the per-repo lock may consume it too
MAX_TURNS    = 40    # forty model round trips, each possibly a test suite
```

Rough budget for one realistic run against a mid-size TS repo:

| Phase | Typical | Notes |
|---|---|---|
| mirror fetch (warm) | 5–20 s | fine |
| `pnpm install --frozen-lockfile` | 60–240 s | warm store helps; still the second-biggest cost |
| agent loop | 180 s – 25 min | **unbounded and bimodal**: a 1-file change is fast, a failing test the agent iterates on is not |
| validation gate (4 commands) | 90 s – 8 min | lint + tsc + test + build, run *again* independently |
| push + `gh pr create` | 5–15 s | fine |

The floor is ~6 minutes. The interesting runs — the ones where the agent reads a
test failure and fixes it, which is the capability being demonstrated — are the
ones that blow past 900s. Truncating those is not a performance regression, it
is **losing exactly the runs the POC exists to show**.

This is the crux. Everything in section 4 is a way of buying time back.

### Trouble 2 — storage. Ephemeral, and the persistent option is slow.

| Option | Size | Persistent | Shared across runs | `flock` | Speed for `node_modules` |
|---|---|---|---|---|---|
| `/tmp` | 512 MB – **10 GB** (configurable) | no | no | yes (local, useless — nothing to contend with) | fast (local NVMe-backed) |
| container image layers | 10 GB | yes | yes | n/a | fast, but **read-only** |
| EFS mount | unlimited | yes | yes | **yes, NFSv4 byte-range locks** | **bad** — see below |
| S3 | unlimited | yes | yes | no (use DynamoDB) | fast in bulk, terrible per-file |

10 GB of `/tmp` is enough for one mirror plus one worktree plus `node_modules`,
so D2 is fine. The problem is D3 + D4 together: a *shared, lockable* cache.

EFS is the obvious answer and the wrong one. It satisfies D3 and D4 exactly —
mount it at `/cache`, `flock` keeps working, `run-agent.sh` barely changes. But
EFS is an NFS mount, and `pnpm install` / `tsc` / `jest` are the worst possible
workload for NFS: hundreds of thousands of tiny stat-and-open calls, each paying
a network round trip. Expect `pnpm install` to go from ~90 s to **5–15 minutes**
on EFS. It spends the entire 900s budget you don't have. EFS also forces the
function into a VPC, which means a NAT gateway (~$32/mo + data) or VPC endpoints
just to reach GitHub, Bedrock and SSM.

**So: EFS is disqualified as the working directory.** The cache design has to
change shape, not just relocate.

## 3. Pros and cons

### Pros of moving to Lambda

| Pro | Substance |
|---|---|
| No idle cost | The box is **$4/day whether or not anyone runs anything**. Lambda at 10 GB is $0.15 for a full 900s run. Under ~26 runs/day Lambda is cheaper; at 2 runs/day it is 13× cheaper. |
| Better burst compute | 10 GB Lambda gets **6 vCPU** vs the `t3.xlarge`'s 4 — and `t3` is *burstable*, so a long `tsc` on a depleted CPU credit balance gets throttled. Lambda doesn't do that. |
| `MAX_CONCURRENT` stops being a lie | Today the ceiling is 2 because the box has 4 vCPU. Reserved concurrency of 20 gives 20 genuinely isolated runs, each with its own 6 vCPU. The parallel smoke test stops being a test of one box's RAM. |
| Real isolation, for free | Each invocation is a fresh microVM. No cross-run state, no leaked processes, no accumulating Postgres containers to `down -v`. The `finish()` teardown hack in `server/index.js:155` disappears. |
| Better security posture | No long-lived host holding a GitHub token in a systemd `ExecStart`. Token fetched per invocation into a filesystem that ceases to exist. No SSM agent, no instance to patch, no `usermod -aG docker`. |
| Removes real operational surface | No AMI, no `dnf update`, no buildx pinning, no `docker compose` plugin-vs-binary branch, no `chown -R ec2-user`. `infra/ec2-userdata.sh` is 79 lines of things that can break before your code runs. |
| Queue becomes durable | SQS replaces the in-memory FIFO. The README's "restarting the console loses history" gotcha is fixed as a side effect, not as extra work. |

### Cons of moving to Lambda

| Con | Substance | Mitigable? |
|---|---|---|
| **15-minute hard ceiling** | Kills the long agent iterations that are the demo. | Only by checkpointing (§4.3). Never fully. |
| Docker is gone | No daemon, no nested containers. `docker-compose.yml` and its Postgres/Redis sidecars cannot be lifted. | Yes — run them as processes (§4.4). |
| Cache must be redesigned | EFS is too slow; `/tmp` isn't shared. D3/D4 need a new mechanism. | Yes — S3 + DynamoDB (§4.2). |
| Debugging gets much worse | You lose `aws ssm start-session` and `watch docker ps`. You diagnosed the cache/lock bugs *by looking at the box*. From Lambda you get CloudWatch and nothing else. | Partially — ship artifacts to S3 on failure. |
| Streaming logs is now work | SSE from a `systemd` process is trivial. From Lambda it's a Function URL in `RESPONSE_STREAM` mode (itself 15-min capped) or CloudWatch tailing. | Yes, but it's real work (§4.5). |
| Cold-start image pull | A 3–5 GB container image (Node + pnpm + Python + gh + postgres + redis) costs 10–40 s on a cold start. | Partially — provisioned concurrency, at which point you're paying for idle again. |
| Per-second cost is higher | 10 GB Lambda is **$0.60/hr** vs `$0.166/hr` for the instance and `$0.233/hr` for Fargate. Lambda only wins because it isn't running. | n/a — it's the right trade at low volume. |
| Bedrock long calls burn the budget | A single Converse call on a large context can take 60–120 s. Ten of those and you're done, having written nothing. | Partially — cap turns per slice. |
| Architectural mismatch, stated plainly | Lambda is for short, stateless, event-shaped work. An agent run is long, stateful and interactive. You will be fighting the primitive for the life of the project. | No. This is the honest con. |

### The one-line verdict

> Lambda is right for the **control plane** and wrong for the **agent run**.
> The 15-minute ceiling is not an inconvenience to engineer around; it is a
> statement that Lambda is not for this workload.

Both options below therefore remove EC2. They differ in what runs the agent.

## 4. Option A — all Lambda, EC2 removed entirely

Doable. Requires redesigning the cache and splitting the run into resumable
slices. Presented in full because it's what was asked for, and because for the
POC's *current* demo tasks (small synthetic repo, one-file changes) it fits.

### 4.1 Target architecture

```
Browser
  │  (static console on S3 + CloudFront)
  ▼
API Gateway HTTP API ──► lambda-api            (256 MB, 10 s)
                            │  POST /api/runs → DynamoDB run item
                            │  GET  /api/runs/:id/stream → SSE from DynamoDB+S3
                            ▼
                         Step Functions state machine  ("run")
                            │
    ┌───────────────────────┼─────────────────────────────┐
    ▼                       ▼                             ▼
lambda-prepare        lambda-agent-slice  ◄── loop ──►  lambda-validate
(3 GB, 10 min)        (10 GB, 14 min)                   (10 GB, 14 min)
 mirror→S3 bundle      N model turns,                     4 checks, then
 install→S3 tarball    checkpoint patch                   lambda-publish
    │                       │                             (push + gh pr create)
    └──────────┬────────────┴───────────────┬─────────────┘
               ▼                            ▼
        S3  poc-agent-cache          DynamoDB  poc-agent-runs
        repos/<org>/<repo>.bundle     run state, log lines,
        deps/<repo>/<lockhash>.tzst   checkpoints, per-repo locks
        runs/<run-id>/patch.diff
        runs/<run-id>/messages.json
```

Bedrock is called from `lambda-agent-slice` exactly as today. `agent.py` is
almost unchanged — see §4.3.

### 4.2 Replacing the cache (fixes D2/D3/D4)

The insight: today's cache is shared *because the filesystem is shared*. On
Lambda, make it shared **because it's in S3**, and make each invocation
materialise a private copy into `/tmp`.

| Today | On Lambda |
|---|---|
| `cache/repos/<org>/<repo>.git` bare mirror | `s3://…/repos/<org>/<repo>.bundle` — a `git bundle`. Downloaded to `/tmp` and cloned from, in one sequential read instead of 100k small ones. |
| `cache/worktrees/<repo>/<run>` | `/tmp/work` — private per invocation, no collision possible, so the branch-collision suffixing in `run-agent.sh:188` is only still needed against the *remote*. |
| `cache/pnpm-store` shared store | `s3://…/deps/<repo>/<sha256 of lockfile>.tar.zst` — a tarball of the whole installed `node_modules`. Restore is one download + one extract: **~20–40 s instead of a 90–240 s install.** This is the single biggest time win available. |
| `cache/locks/*.lock` + `flock` | DynamoDB conditional-write lock with a TTL. |

The dependency cache keyed on the lockfile hash is worth stating separately: it
replaces the *slowest* phase with a bulk S3 read, and it's the reason Option A
fits in 900s at all. Lockfile unchanged ⇒ no install, ever again.

Lock replacement — same semantics as `flock -w`, ~15 lines:

```python
# lock.py — replaces flock for D4
import time, boto3, botocore
_t = boto3.resource("dynamodb").Table("poc-agent-locks")

def acquire(key, owner, ttl=900, wait=900):
    deadline = time.time() + wait
    while True:
        try:
            _t.put_item(
                Item={"pk": key, "owner": owner, "expires": int(time.time()) + ttl},
                ConditionExpression="attribute_not_exists(pk) OR expires < :now",
                ExpressionAttributeValues={":now": int(time.time())},
            )
            return True
        except botocore.exceptions.ClientError as e:
            if e.response["Error"]["Code"] != "ConditionalCheckFailedException":
                raise
            if time.time() > deadline:
                return False
            time.sleep(2)

def release(key, owner):
    try:
        _t.delete_item(Key={"pk": key},
            ConditionExpression="owner = :o",
            ExpressionAttributeValues={":o": owner})
    except botocore.exceptions.ClientError:
        pass  # already expired; another owner holds it
```

Note the TTL does what `flock` got for free: a Lambda killed at 900s cannot run
its `cleanup()` trap, so a lock with no expiry would wedge a repo permanently.

### 4.3 Beating the 15-minute ceiling (D1) — checkpoint the *conversation*, not the disk

The naive continuation is to tar `/tmp/work` to S3 between slices. Don't: with
`node_modules` that's 0.5–1.5 GB and 30–60 s each way, spent on both ends of
every slice.

Checkpoint the two things that are actually irreproducible, both tiny:

1. `git diff` against the base — the agent's work so far. Kilobytes.
2. the Converse `messages` array — the agent's memory. Hundreds of KB.

Everything else (worktree, `node_modules`) is *rebuilt from cache*, which §4.2
already made fast.

```
slice N:  restore  →  clone from bundle (5s) + restore deps tarball (30s)
                   →  git apply patch.diff (instant)
                   →  load messages.json
          work     →  run up to TURNS_PER_SLICE model turns, watching a deadline
          persist  →  git diff > patch.diff ; messages.json  → S3
          return   →  {done: false, turns_used: 12}
```

Step Functions drives the loop, so no Lambda ever waits on another:

```json
{
  "AgentSlice": {
    "Type": "Task",
    "Resource": "arn:aws:states:::lambda:invoke",
    "Parameters": {"FunctionName": "poc-agent-slice", "Payload.$": "$"},
    "ResultSelector": {"done.$": "$.Payload.done", "turns.$": "$.Payload.turns"},
    "ResultPath": "$.slice",
    "Retry": [{"ErrorEquals": ["Lambda.ServiceException", "States.TaskFailed"],
               "MaxAttempts": 1}],
    "Next": "MoreWork?"
  },
  "MoreWork?": {
    "Type": "Choice",
    "Choices": [
      {"Variable": "$.slice.done", "BooleanEquals": true, "Next": "Validate"},
      {"Variable": "$.slice.turns", "NumericGreaterThanEquals": 40, "Next": "GaveUp"}
    ],
    "Default": "AgentSlice"
  }
}
```

The changes to `agent.py` are small and worth being precise about:

| Change | Why |
|---|---|
| accept a `messages` list on entry, return it on exit | it's already a local variable in the Converse loop; hoist it to a parameter |
| take a `deadline` (epoch seconds) and stop cleanly before it | `deadline = start + 780` inside a 900s function leaves 120 s to persist |
| check the deadline **before** each Converse call and before each `run_bash` | a call started at t=770 with a 120 s response overruns; refusing to start it is the only safe check |
| lower `BASH_TIMEOUT` from 900 → `min(600, deadline - now)` | 900 is nonsensical inside a 900s function |
| write the checkpoint in a `finally` | so even an unexpected exception doesn't lose 12 turns of work |

Set `TURNS_PER_SLICE` conservatively (8–12). A slice that ends early is cheap; a
slice killed at 900s loses everything since its last checkpoint.

**Honest limitation:** a *single* `run_bash` that legitimately needs more than
~12 minutes — a full integration suite on a large repo — cannot be split and
will never pass on Lambda. This is not solvable within Option A. If your target
repo has such a suite, stop here and take Option B.

### 4.4 Replacing the Docker sidecars (D5)

No daemon, so `docker-compose.yml` is deleted. Postgres and Redis become
processes inside the Lambda container image — which preserves the per-run
isolation the README correctly identifies as load-bearing, and is *stronger*
than compose projects because the microVM boundary is real.

```dockerfile
# in the Lambda image
RUN apt-get update && apt-get install -y --no-install-recommends \
      postgresql-16 redis-server && rm -rf /var/lib/apt/lists/*
```

```bash
# sidecars.sh — sourced by the runner before the install step
export PGDATA=/tmp/pgdata PGHOST=/tmp PGPORT=5432
setpriv --reuid postgres --regid postgres --clear-groups initdb -U postgres -A trust -D "$PGDATA" >/dev/null
setpriv --reuid postgres --regid postgres --clear-groups pg_ctl -D "$PGDATA" -o "-k /tmp -h 127.0.0.1 -c fsync=off \
  -c full_page_writes=off -c synchronous_commit=off" -w start
createdb -h 127.0.0.1 -U postgres app_test
redis-server --port 6379 --bind 127.0.0.1 --save '' --appendonly no --daemonize yes

export DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/app_test
export REDIS_URL=redis://127.0.0.1:6379
```

`fsync=off` and friends are safe here and materially faster: the data directory
is in `/tmp` and is guaranteed to be destroyed. Cost is ~3–6 s of startup and
~250 MB of image, against the ~15 s and two containers compose needed.

Alternative if the target repo's suite is too heavy for an in-Lambda Postgres:
one Aurora Serverless v2 cluster, one **database per run**, dropped at the end.
Cheaper in image size, but reintroduces a VPC, a NAT and shared state — and
`ACU` minimums mean it isn't free at idle. Prefer the in-process Postgres.

### 4.5 Replacing the console (D6/D7)

`server/index.js` splits in two. The parts that are pure HTTP survive; the part
that spawns a child process and reads its stdout does not.

| Today | On Lambda |
|---|---|
| `spawn(compose)` + `child.stdout.on('data')` | gone — nothing to spawn |
| `ingest()` regex parsing of `=== phase ===` / `PASS x` | **keep it**, but run it *inside* the worker, which writes structured events straight to DynamoDB. Parsing your own stdout with regexes was always a workaround for the child-process boundary; that boundary is gone, so delete the regexes and emit events directly. |
| `runs` Map + `queue` array + `MAX_CONCURRENT` | DynamoDB table + Step Functions + reserved concurrency |
| SSE from a long-lived process | `lambda-api` Function URL with `InvokeMode: RESPONSE_STREAM`, polling the DynamoDB run item every 500 ms and streaming deltas. Simpler and adequate: have the browser poll `GET /api/runs/:id?since=<seq>` every second. For a demo console, polling is the right call — it can't be killed by the streaming function's own 15-min cap mid-demo. |
| `finish()` compose teardown | deleted. Nothing to tear down. |

Losing the SSE stream is a real cost: the live log *is* the demo. Polling at 1 Hz
looks identical to an audience.

### 4.6 Migration steps

Ordered so each step is independently verifiable and nothing is deleted before
its replacement works.

| Step | Work | Verify |
|---|---|---|
| 1 | DynamoDB tables `poc-agent-runs`, `poc-agent-locks` (TTL on `expires`); S3 bucket `poc-agent-cache` (versioning off, lifecycle expiring `runs/` at 7 days) | `aws dynamodb describe-table` |
| 2 | Add `lock.py`; port `run-agent.sh`'s `flock` sections to it behind a `LOCK_BACKEND` env switch | run the existing parallel smoke test **on the EC2 box** with `LOCK_BACKEND=dynamodb` — same assertions must pass |
| 3 | `cache.py`: bundle push/pull + deps tarball push/pull. Wire into `run-agent.sh` behind `CACHE_BACKEND=s3` | still on EC2: second run of a repo must log a deps cache hit and skip install |
| 4 | Build the Lambda container image (`agent/Dockerfile.lambda`): today's image + `postgres-16` + `redis-server` + the RIC entrypoint | `docker run` it locally with the RIE; assert < 10 GB |
| 5 | `sidecars.sh`; delete `docker-compose.yml` | target repo's test suite passes against the in-process Postgres, on EC2 first |
| 6 | Refactor `agent.py` for `messages` in/out + `deadline` (§4.3). No Lambda yet | a run with `TURNS_PER_SLICE=5` resumed 3× by hand produces the same diff as one unsliced run |
| 7 | Deploy `lambda-prepare` / `-agent-slice` / `-validate` / `-publish`, 10 GB memory, 10 GB ephemeral, 900 s timeout | invoke each in isolation with a fixed payload |
| 8 | Step Functions state machine; reserved concurrency = intended `MAX_CONCURRENT` | one end-to-end `DRY_RUN=1` run |
| 9 | `lambda-api` + API Gateway + static console on S3/CloudFront | the console drives a real run |
| 10 | Re-run `scripts/parallel-smoke.sh` against the API URL | the *existing* assertions: one bundle create per repo, N distinct branches, N distinct worktrees |
| 11 | IAM: split the one instance role into four function roles, each narrowed | `lambda-agent-slice` must **not** have `s3:PutObject` on `repos/*` or any GitHub token access — it can't push, mirroring the `DENIED` list in `agent.py:46` at the IAM layer |
| 12 | Terminate the instance; delete `infra/ec2-userdata.sh`, `infra/launch-instance.sh`, `agent/docker-compose.yml`, the `spawn` half of `server/index.js` | `aws ec2 describe-instances` empty; billing drops to ~$0 idle |

Step 11 is worth dwelling on. Today the agent is prevented from pushing by a
string blocklist in Python (`agent.py:46`) — defence by grep. On Lambda the
agent slice and the publisher are *different functions with different IAM
roles*, so the agent cannot reach GitHub credentials at all. **The strongest
argument for this migration is that it turns the POC's central guardrail from a
blocklist into an IAM boundary.**

### 4.7 What Option A costs you

- Runs needing >~40 min total, or any single command >~12 min, will not complete.
- Debugging is CloudWatch-only. Budget for shipping the worktree to S3 on failure.
- ~2 weeks of work, most of it in steps 3, 6 and 9.
- Permanent complexity: a Step Functions loop and a checkpoint format that a
  reader of `run-agent.sh` today would not need to understand.

## 5. Option B — Lambda control plane + Fargate worker (recommended)

Same removal of EC2. Same S3/DynamoDB cache from §4.2, same IAM split from §4.6
step 11, same static console. The difference: the agent run is an **ECS Fargate
task** instead of a chain of Lambda slices.

```
API Gateway ──► lambda-api ──► SQS ──► lambda-dispatcher
                    ▲                      │ ecs:RunTask
                    │                      ▼
              DynamoDB (runs) ◄──── Fargate task (4 vCPU / 16 GB / 40 GB ephemeral)
                                      runs run-agent.sh essentially UNCHANGED,
                                      with sidecars as ECS containers in the
                                      same task definition (localhost networking)
```

What this buys:

| | Option A (all Lambda) | Option B (Lambda + Fargate) |
|---|---|---|
| Time limit | **900 s per slice**, checkpointed | none (or whatever you set) |
| `run-agent.sh` | split into 4 functions + checkpoint protocol | ~unchanged; still one linear script |
| `agent.py` | needs `messages` in/out + deadline logic | **unchanged** |
| Docker sidecars | rewritten as in-image processes | **kept** — sidecar containers in the task definition, same `localhost` semantics as compose |
| `docker-compose.yml` | deleted | maps ~1:1 to the task definition |
| Cache | S3 bundles + deps tarballs (required) | same design, but 40 GB task ephemeral storage means it's an optimisation, not a prerequisite |
| Idle cost | $0 | $0 |
| Cost / 20-min run | ~$0.20 (2 slices at 10 GB) | **~$0.08** |
| Debugging | CloudWatch only | `aws ecs execute-command` — a shell in the running task, i.e. **you keep D8** |
| Concurrency | reserved concurrency | task count; no artificial ceiling |
| New concepts to learn | Step Functions, checkpoint format | one task definition |
| Est. effort | ~2 weeks | **~4 days** |

Option B is cheaper per run, less code, keeps `agent.py` untouched, keeps
interactive debugging, and has no ceiling to engineer around. Fargate is as
serverless as Lambda by every definition that matters here: no instance, no AMI,
no patching, no idle bill.

The only thing Option A has over it is "Lambda-only" as a property. If that
property is a real constraint — an org policy, a platform team that only runs
Lambda — take A. If it's a preference, take B.

**AWS CodeBuild** is a third variant of the same shape and worth 10 minutes of
consideration: `codebuild:StartBuild` from `lambda-dispatcher`, a `buildspec.yml`
instead of a task definition, log streaming and artifact upload built in, and a
Docker daemon available so `docker-compose.yml` survives verbatim. Less control
over networking; the fastest possible port of what you have today.

## 6. Recommendation

1. **Do §4.2 and §4.6 step 11 regardless of which option wins.** The S3 bundle +
   lockfile-keyed dependency cache is the biggest single performance win
   available and is a prerequisite for A, an optimisation for B. The IAM split
   is a genuine security improvement over the string blocklist either way.
2. **Take Option B.** Lambda for API, dispatch, and PR publishing; Fargate for
   the agent run. EC2 is removed, the idle bill goes to zero, `agent.py` doesn't
   change, and there is no 15-minute cliff waiting to eat the one run you most
   wanted to demo.
3. **Take Option A only if Lambda-only is a hard constraint** — and then measure
   first (below), because the answer is empirical.

### The measurement that settles it

Before writing any of this, get the distribution of run durations. One command
on the existing box:

```bash
# per-phase wall clock across the runs you've already done
for d in /opt/poc/agent/logs/*/; do
  printf '%s  install=%ss agent=%ss validate=%ss\n' "$(basename "$d")" \
    "$(stat -c %Y "$d/install.log" 2>/dev/null)" \
    "$(stat -c %Y "$d/agent.log" 2>/dev/null)" \
    "$(stat -c %Y "$d/validation.log" 2>/dev/null)"
done
```

Better, instrument it properly — add `date +%s` markers around each phase in
`run-agent.sh` and run ten realistic tasks. Then:

- **p95 total < 10 min and no single command > 8 min** → Option A is comfortable;
  the Lambda-only constraint costs you little.
- **p95 total 10–35 min** → Option A works but only via checkpointing, and you
  will be tuning `TURNS_PER_SLICE` for a while. Option B is plainly better.
- **p95 > 35 min, or any single command > 12 min** → Option A is not viable.
  Take Option B and don't revisit it.

The README already says the honest POC result is "two or three out of five
produced a mergeable PR". The runs that fail are the slow ones. Choosing an
architecture that truncates slow runs will make that number look better while
making the system worse — which is the specific trap this document exists to
avoid.

## 7. Cost review — which option is actually cheap

All prices us-east-1, on-demand, at the time of writing. Verify before quoting
any of it: `aws pricing get-products` or the pricing calculator.

### 7.1 Per second of compute, Lambda is the *most expensive* option

| Config | $/hr of real compute | vs EC2 |
|---|---|---|
| **Lambda 10 GB + 10 GB ephemeral** | **$0.601** | **3.6× more expensive** |
| Fargate 4 vCPU / 16 GB | $0.233 | 1.4× |
| Fargate 4 vCPU / 8 GB | $0.197 | 1.2× |
| `t3.xlarge` on-demand | $0.166 | 1.0× |
| Fargate Spot 4 vCPU / 16 GB | $0.070 | 0.4× |

Lambda never wins on rate. It wins on **duty cycle** — it costs nothing when
idle, and this workload is idle ~98% of the time.

There's a trap inside that first row worth stating on its own:

> **The 15-minute limit forces you onto Lambda's most expensive configuration.**
> You don't need 10 GB of *memory*; you need the 6 vCPUs that only come bundled
> with it. Drop to 3.5 GB and you get 2 vCPU at $0.21/hr — cheaper per second,
> but the run takes ~2× longer, and a 2×-longer run hits the 900s wall. So the
> usual lever for cutting Lambda cost (right-size the memory) is unavailable
> here. Fargate decouples them: 4 vCPU with 8 GB is a legal shape, Lambda has no
> equivalent.

### 7.2 Cost per run

Lambda column includes the Step Functions transitions, the per-slice cache
restore (~35 s billed each), ephemeral storage above 512 MB, and S3/DynamoDB
I/O. Fargate includes the public IPv4 hourly charge. EC2 assumes start-on-demand
/ stop-when-idle, with 2 minutes of boot billed.

| Run length | Lambda (Option A) | Fargate (Option B) | EC2 start/stop |
|---|---|---|---|
| 8 min | $0.087 | $0.032 | $0.028 |
| 15 min | $0.143 | $0.060 | $0.047 |
| **20 min** | **$0.184** | **$0.079** | **$0.061** |
| 35 min | $0.310 | $0.139 | $0.103 |
| 60 min | $0.516 | $0.238 | $0.172 |

Lambda costs ~2.3× Fargate per run, and the gap widens with run length because
slicing overhead compounds.

### 7.3 Monthly total, 20-minute runs, compute only

| runs/day | Lambda A | Fargate B | Fargate Spot | **EC2 24/7 (today)** | EC2 stop/start |
|---|---|---|---|---|---|
| 1 | $5.51 | $2.38 | $0.76 | **$126.27** | $6.63 |
| **2** | **$11.01** | **$4.76** | **$1.52** | **$126.27** | $8.46 |
| 5 | $27.53 | $11.90 | $3.81 | **$126.27** | $13.95 |
| 10 | $55.05 | $23.80 | $7.62 | **$126.27** | $23.10 |
| 25 | $137.63 | $59.51 | $19.04 | $126.27 | $50.56 |
| 50 | $275.25 | $119.02 | $38.09 | $126.27 | $96.32 |
| 100 | $550.51 | $238.04 | $76.17 | **$126.27** | $187.84 |

Break-even against the always-on instance:

| Option | Break-even |
|---|---|
| Lambda A | 23 runs/day |
| Fargate B | 53 runs/day |
| Fargate Spot | 166 runs/day |

**The expensive solution today is the one you're running.** At a POC's actual
volume — call it 2 runs/day — the `t3.xlarge` is $126/mo for roughly 20 hours of
real compute per month. That's an effective **$6.31 per compute-hour** for a box
whose list price is $0.166/hr: a 38× markup, all of it paid for idle time.
Anything serverless is 10–25× cheaper at that volume.

### 7.4 The expensive traps, ranked

Every one of these is a way to spend EC2 money without an EC2:

| $/mo fixed | Trap | Why it happens |
|---|---|---|
| **$126** | EC2 running 24/7 | the status quo |
| **$110** | **Lambda 10 GB provisioned concurrency, ×1** | added to fix a 10–40 s cold start. You have now rebuilt the always-on instance, at 87% of the price, *and kept the 15-minute limit*. Never do this. |
| $44 | Aurora Serverless v2 at its 0.5-ACU floor | the "just use a managed Postgres" instinct from §4.4. Serverless v2 does not scale to zero. |
| **$33** | **NAT gateway** | charged the moment the function goes into a VPC — which EFS and RDS both require. A hard $33 floor before a single run, purely to let a private-subnet Lambda reach GitHub. |
| $6 + throughput | EFS as the working cache | **double penalty**: you pay for the storage *and* the slow NFS metadata path makes every run longer, which costs more Lambda-seconds, on the most expensive per-second platform. |
| $5 | 60 GB gp3, instance stopped | EBS bills while stopped. The floor under "EC2 start/stop". |
| **$0.76** | **S3 + DynamoDB cache (§4.2)** | the design this doc recommends |
| **$0** | Lambda or Fargate, no VPC, no provisioned concurrency | |

Two of these are the reason §4.2 chose S3 and DynamoDB over the obvious EFS
lift-and-shift. It isn't only that EFS is slow — **staying out of a VPC saves
$33/mo of NAT before anything else happens**, and S3+DynamoDB are the only cache
primitives reachable from a VPC-less Lambda.

### 7.5 The number that makes this whole section nearly irrelevant

The README says Bedrock is "a few dollars per run". Take $3:

| Volume | Option | Compute | Bedrock | Total | Compute share |
|---|---|---|---|---|---|
| 2/day | Lambda A | $11.01 | $180 | $191.01 | 5.8% |
| 2/day | Fargate B | $4.76 | $180 | $184.76 | **2.6%** |
| 2/day | EC2 24/7 | $126.27 | $180 | $306.27 | 41.2% |
| 5/day | Fargate B | $11.90 | $450 | $461.90 | 2.6% |
| 25/day | Lambda A | $137.63 | $2,250 | $2,387.63 | 5.8% |
| 25/day | Fargate B | $59.51 | $2,250 | $2,309.51 | 2.6% |

So, honestly:

1. **Getting off the always-on instance is the one decision that matters.** It
   cuts the bill 41% → 3% of total at POC volume. Worth ~$120/mo.
2. **Lambda vs Fargate is worth about $6/mo at 2 runs/day.** Choose on the 15-minute
   limit and the debugging story (§5), not on price. Price is a rounding error
   between them.
3. **The real cost lever is tokens, not compute.** At 2 runs/day, compute is
   $4.76 and inference is $180. Anything that cuts token spend beats any
   infrastructure choice here by 10–50×:
   - Bedrock **prompt caching** on the system prompt + `AGENT_RULES.md` + the
     stable prefix of the message history. The Converse loop re-sends the entire
     history every turn, so by turn 30 you are paying full input price on the
     same 100 KB thirty times over. This is the single biggest saving available
     in the whole system.
   - `MAX_ITERATIONS` (40) and `MAX_TOKENS_TOTAL` (2 M) are spend ceilings, not
     just safety rails. A 2 M-token run is a *$6–10* run.
   - Truncating tool output harder than 6 KB, and not re-reading files the agent
     has already read.
   - A cheaper model for the early exploration turns, escalating only to edit.

   Note a cost interaction with Option A: slicing the conversation across Lambda
   invocations risks losing Bedrock prompt-cache hits at every slice boundary
   (the cache is content-keyed with a short TTL). If that happens it costs more
   in *tokens* than Option A's entire compute bill. Measure cache-hit tokens
   before and after slicing.

### 7.6 Verdict

| | Cheapest | Most expensive |
|---|---|---|
| **Per second of compute** | Fargate Spot ($0.070/hr) | **Lambda 10 GB ($0.601/hr)** |
| **Per run** | EC2 start/stop ($0.061) → Fargate ($0.079) | **Lambda ($0.184)** |
| **Per month at POC volume (2/day)** | Fargate Spot ($1.52) → Fargate ($4.76) | **EC2 24/7 ($126.27)** |
| **Fixed floor** | Lambda/Fargate with no VPC ($0) | EC2 24/7 ($126) / Lambda + provisioned concurrency ($110) |
| **Total bill including Bedrock** | Fargate B — but only 3% better than Lambda A | EC2 24/7 |

Cheapest realistic choice: **Fargate on demand**, no NAT (public subnet with an
assigned public IP), S3 + DynamoDB cache, no provisioned anything — $4.76/mo at
2 runs/day, and it's also Option B, which is what §6 recommends on engineering
grounds. The cost analysis and the architecture analysis agree, which is
convenient but not why the recommendation is what it is.

Add **Fargate Spot** later if you want: 3× cheaper again, and the §4.3
checkpoint mechanism is exactly what makes an interrupted task survivable. That
is the one place Option A's design work pays off inside Option B.

Most expensive choice: keeping the instance up. Second most expensive: moving to
Lambda and then adding provisioned concurrency to make it feel responsive.
