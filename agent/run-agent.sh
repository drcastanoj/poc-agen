#!/usr/bin/env bash
# Akai coding agent — week 1 MVP runner.
#
# Usage:
#   ./run-agent.sh <repo> <JIRA-TICKET> "<task description>"
#
# Example:
#   ./run-agent.sh deel-duty DUTY-123 "Remove the Profile option from the UI sidebar"
#
# Required env:
#   BEDROCK_MODEL_ID    e.g. an inference-profile id from
#                       aws bedrock list-inference-profiles
#   AWS_REGION          Bedrock region, e.g. us-east-1
#   GH_TOKEN            GitHub token with contents + PR write on the target repo
#
# AWS credentials come from the instance role via the default SDK chain.
#
# Optional env:
#   GITHUB_ORG          default: letsdeel
#   BASE_BRANCH         default: dev
#   MAX_TURNS           model round trips, default: 40
#   DRY_RUN             set to 1 to stop before push/PR

set -euo pipefail

REPO="${1:?usage: run-agent.sh <repo> <TICKET> \"<task>\"}"
TICKET="${2:?usage: run-agent.sh <repo> <TICKET> \"<task>\"}"
TASK="${3:?usage: run-agent.sh <repo> <TICKET> \"<task>\"}"

GITHUB_ORG="${GITHUB_ORG:-letsdeel}"
BASE_BRANCH="${BASE_BRANCH:-dev}"
MAX_TURNS="${MAX_TURNS:-40}"
DRY_RUN="${DRY_RUN:-0}"

: "${BEDROCK_MODEL_ID:?BEDROCK_MODEL_ID must be set (see README step 1)}"
: "${AWS_REGION:?AWS_REGION must be set}"
: "${GH_TOKEN:?GH_TOKEN must be set}"
export BEDROCK_MODEL_ID AWS_REGION

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
WORK="/work/${REPO}-${TICKET}-${RUN_ID}"
LOGS="/work/logs/${RUN_ID}"
mkdir -p "$LOGS"

log() { printf '\n=== %s ===\n' "$*"; }

# --- derive a Deel-convention branch name -----------------------------------
slug=$(printf '%s' "$TASK" \
  | tr '[:upper:]' '[:lower:]' \
  | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' \
  | cut -c1-40 | sed -E 's/-+$//')
BRANCH="${TICKET}-${slug}"

log "run $RUN_ID | repo=$REPO branch=$BRANCH base=$BASE_BRANCH"

# --- 1. checkout -------------------------------------------------------------
log "cloning"
git clone --depth 50 --branch "$BASE_BRANCH" \
  "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_ORG}/${REPO}.git" "$WORK"
cd "$WORK"

git config user.name  "${GIT_AUTHOR_NAME:-akai-agent}"
git config user.email "${GIT_AUTHOR_EMAIL:-akai-agent@deel.com}"
git checkout -b "$BRANCH"

# --- 2. install --------------------------------------------------------------
log "installing dependencies"
if [ -d /pnpm-store ]; then pnpm config set store-dir /pnpm-store; fi
pnpm install --frozen-lockfile 2>&1 | tee "$LOGS/install.log"

# --- 3. agent loop -----------------------------------------------------------
# The agent iterates on its own: edit, run lint/test, read the failure, fix.
# We do NOT trust its self-report — step 4 re-runs everything independently.
log "running agent"
PROMPT=$(cat <<EOF
Task: ${TASK}

Jira ticket: ${TICKET}
Repository: ${GITHUB_ORG}/${REPO}
Branch: ${BRANCH} (already created from ${BASE_BRANCH}; you are on it)

Implement this change. After editing, run the validation commands yourself and
keep iterating until every one of them exits zero:

  pnpm lint
  pnpm exec tsc --noEmit
  pnpm test
  pnpm build

Do not commit, push, or open a pull request — the harness handles that.
Do not modify CI configuration, lockfiles, or unrelated files.
When you are done, print a short summary of what you changed and why.
EOF
)

set +e
REPO_ROOT="$WORK" \
RULES_FILE="$SCRIPT_DIR/AGENT_RULES.md" \
AGENT_SUMMARY_FILE="$LOGS/agent.json" \
MAX_ITERATIONS="$MAX_TURNS" \
  python3 "$SCRIPT_DIR/agent.py" "$PROMPT" 2>&1 | tee "$LOGS/agent.log"
AGENT_EXIT=${PIPESTATUS[0]}
set -e

jq -r '.summary // "no summary recorded"' "$LOGS/agent.json" > "$LOGS/agent-summary.txt" 2>/dev/null \
  || echo "no summary recorded" > "$LOGS/agent-summary.txt"
jq -r '"tokens in=\(.input_tokens) out=\(.output_tokens)"' "$LOGS/agent.json" \
  > "$LOGS/usage.txt" 2>/dev/null || true

if [ "$AGENT_EXIT" -ne 0 ]; then
  log "agent exited $AGENT_EXIT — see $LOGS/agent.err"
  exit "$AGENT_EXIT"
fi

if git diff --quiet && git diff --cached --quiet; then
  log "agent produced no changes — stopping"
  exit 1
fi

# --- 4. independent validation gate -----------------------------------------
# This is the gate, not the agent's opinion. Any failure here blocks the PR.
log "validating"
: > "$LOGS/validation.log"
FAILED=""
for step in \
  "lint:pnpm lint" \
  "typecheck:pnpm exec tsc --noEmit" \
  "test:pnpm test" \
  "build:pnpm build"
do
  name="${step%%:*}"; cmd="${step#*:}"
  printf '\n----- %s -----\n' "$name" >> "$LOGS/validation.log"
  if eval "$cmd" >> "$LOGS/validation.log" 2>&1; then
    echo "PASS $name"
  else
    echo "FAIL $name"
    FAILED="${FAILED} ${name}"
  fi
done

if [ -n "$FAILED" ]; then
  log "validation failed:${FAILED} — no PR opened. See $LOGS/validation.log"
  exit 1
fi

# --- 5. commit and PR --------------------------------------------------------
SUMMARY=$(head -c 2000 "$LOGS/agent-summary.txt")

git add -A
git commit -m "feat: ${TASK}" -m "${TICKET}"

if [ "$DRY_RUN" = "1" ]; then
  log "DRY_RUN=1 — stopping before push. Worktree: $WORK"
  exit 0
fi

log "pushing and opening PR"
git push -u origin "$BRANCH"

gh pr create \
  --repo "${GITHUB_ORG}/${REPO}" \
  --base "$BASE_BRANCH" \
  --head "$BRANCH" \
  --title "${TICKET}: ${TASK}" \
  --body "$(cat <<EOF
## Summary

${SUMMARY}

## Validation

All checks run in an isolated sandbox before this PR was opened:

| Check | Result |
|---|---|
| \`pnpm lint\` | pass |
| \`pnpm exec tsc --noEmit\` | pass |
| \`pnpm test\` | pass |
| \`pnpm build\` | pass |

## Notes

Generated by the Akai coding agent (run \`${RUN_ID}\`). Needs human review before merge.

${TICKET}
EOF
)"

log "done — worktree at $WORK, logs at $LOGS"
