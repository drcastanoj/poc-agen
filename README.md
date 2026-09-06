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
  index.js            demo console: starts runs, streams logs
  public/index.html
infra/
  ec2-userdata.sh
  instance-role-policy.json
```

## How it works

`run-agent.sh` clones the repo, installs dependencies, then hands control to
`agent.py`, which loops against Bedrock with five tools: `read_file`,
`list_files`, `edit_file`, `write_file`, `run_bash`. The agent explores, edits,
runs lint and tests, reads failures, and fixes them.

When the agent stops, **the harness re-runs all four validation commands
itself**. The PR is opened only if every one exits zero. This is the load-bearing
design decision: the agent cannot self-certify, and it cannot reach around the
gate because `git push`, `git commit` and `gh` are blocked in `run_bash`.

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

- AMI: Amazon Linux 2023, x86_64
- Type: `t3.xlarge` (4 vCPU / 16 GB). `pnpm install` plus a Postgres container
  will thrash anything smaller.
- Storage: 60 GB gp3
- IAM instance profile: `poc-coder-agent`
- Security group: **no inbound rules at all**
- User data: `infra/ec2-userdata.sh`, with `POC_REPO_URL` edited first

Reach the console over an SSH tunnel:

```bash
ssh -i key.pem -L 8080:localhost:8080 ec2-user@<instance-ip>
# then open http://localhost:8080
```

A box that spawns containers and holds a GitHub token has no business being
publicly reachable, and the tunnel is one extra flag.

## Step 5 — smoke test

```bash
ssh -i key.pem ec2-user@<instance-ip>
cd /opt/poc/agent
docker compose build

export AWS_REGION=us-east-1
export BEDROCK_MODEL_ID=<id from step 1>
export GITHUB_ORG=YOUR_GITHUB_USER
export BASE_BRANCH=main
export GH_TOKEN=$(aws ssm get-parameter --name /poc/github-token \
  --with-decryption --query Parameter.Value --output text --region us-east-1)

DRY_RUN=1 docker compose run --rm agent demo-service POC-1 \
  "Remove the Profile item from the sidebar navigation"
```

`DRY_RUN=1` stops before push and leaves the tree for inspection. Only drop it
once a dry run produces a diff you'd have accepted yourself.

Container credentials: on EC2 the agent container reaches the instance metadata
service for the role. If boto3 reports no credentials, check that Docker isn't
blocking the link-local metadata address, or pass a short-lived
`AWS_CONTAINER_CREDENTIALS_FULL_URI`.

## Step 6 — the console

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
  say so rather than being asked.

## What this deliberately omits

Job queue, per-run ephemeral sandboxes, GitHub App auth, egress allowlisting,
multi-repo config, an eval harness. Each matters before this touches a real
repository on shared infrastructure. None is needed to answer the only question
a POC exists to answer: can it write a pull request someone would merge?
