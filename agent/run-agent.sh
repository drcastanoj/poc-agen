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
#   GITHUB_ORG          default: drcastanoj
#   BASE_BRANCH         default: main
#   MAX_TURNS           model round trips, default: 40
#   DRY_RUN             set to 1 to stop before push/PR
#   RUN_ID              unique id for this run. The console passes its own run
#                       id; a timestamp+pid fallback is used standalone. MUST be
#                       unique across concurrent runs — it names the worktree
#                       and the log directory.
#   CACHE_ROOT          default: /cache. Persistent, shared across runs:
#                         $CACHE_ROOT/repos/<org>/<repo>.git   bare mirror
#                         $CACHE_ROOT/worktrees/<repo>/<run>   per-run checkout
#                         $CACHE_ROOT/locks/<org>__<repo>.lock per-repo lock
#   KEEP_WORKTREE       set to 1 to leave the worktree on disk for inspection.
#                       Implied by DRY_RUN=1.
#   LOCK_TIMEOUT        seconds to wait for the per-repo lock, default: 900
#   LINT_CMD, TYPECHECK_CMD, TEST_CMD, BUILD_CMD
#                       override the validation gate commands. Defaults are
#                       derived from the target repo's lockfile (pnpm / yarn /
#                       npm) and package.json scripts.
#
# Serverless env (see docs/lambda-migration.md) — all optional, all default to
# today's EC2 behaviour:
#   CACHE_BACKEND       fs (default) | s3. On s3, CACHE_ROOT is just a scratch
#                       dir (e.g. Fargate ephemeral storage) — the mirror and
#                       the installed node_modules are seeded from CACHE_BUCKET
#                       instead of being already-there on a shared disk.
#   CACHE_BUCKET        required when CACHE_BACKEND=s3.
#   LOCK_BACKEND        flock (default) | dynamodb. On dynamodb, LOCK is a key
#                       in LOCK_TABLE rather than a bind-mounted file — needed
#                       because Fargate tasks don't share a disk to flock.
#   LOCK_TABLE          required when LOCK_BACKEND=dynamodb.
#   PUBLISH_MODE        inline (default) | deferred. On deferred, this script
#                       never commits, pushes, or opens a PR — it stops after
#                       validation and writes a patch + metadata to
#                       CACHE_BUCKET for a separate, narrowly-permissioned
#                       publish step to apply. This is the IAM boundary
#                       replacing the DENIED-command blocklist: a task running
#                       in deferred mode need not hold a GitHub token capable
#                       of writing at all.
#   RUN_TABLE           optional even in deferred mode. When set, run status
#                       is mirrored to this DynamoDB table for a console to
#                       poll instead of tailing a live process's stdout.

set -euo pipefail

REPO="${1:?usage: run-agent.sh <repo> <TICKET> \"<task>\"}"
TICKET="${2:?usage: run-agent.sh <repo> <TICKET> \"<task>\"}"
TASK="${3:?usage: run-agent.sh <repo> <TICKET> \"<task>\"}"

GITHUB_ORG="${GITHUB_ORG:-drcastanoj}"
BASE_BRANCH="${BASE_BRANCH:-main}"
MAX_TURNS="${MAX_TURNS:-40}"
DRY_RUN="${DRY_RUN:-0}"
CACHE_ROOT="${CACHE_ROOT:-/cache}"
LOCK_TIMEOUT="${LOCK_TIMEOUT:-900}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)-$$}"
KEEP_WORKTREE="${KEEP_WORKTREE:-0}"
[ "$DRY_RUN" = "1" ] && KEEP_WORKTREE=1

# Serverless toggles — all default to today's EC2 behaviour. See the header
# comment and docs/lambda-migration.md.
CACHE_BACKEND="${CACHE_BACKEND:-fs}"
LOCK_BACKEND="${LOCK_BACKEND:-flock}"
PUBLISH_MODE="${PUBLISH_MODE:-inline}"
export CACHE_BACKEND LOCK_BACKEND LOCK_OWNER="$RUN_ID"

: "${BEDROCK_MODEL_ID:?BEDROCK_MODEL_ID must be set (see README step 1)}"
: "${AWS_REGION:?AWS_REGION must be set}"
: "${GH_TOKEN:?GH_TOKEN must be set}"
export BEDROCK_MODEL_ID AWS_REGION GH_TOKEN

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/cache.sh
source "$SCRIPT_DIR/lib/cache.sh"
# shellcheck source=lib/lock.sh
source "$SCRIPT_DIR/lib/lock.sh"
# shellcheck source=lib/report.sh
source "$SCRIPT_DIR/lib/report.sh"

log() { printf '\n=== %s ===\n' "$*"; }

# --- resolve a typo'd repo name ---------------------------------------------
# This is an unattended run — there's no one to ask — so a repo name that
# doesn't exist gets one attempt at inference before failing. Without this, a
# typo dies 30+ seconds later as a bare `remote: Repository not found.`, deep
# inside the clone, with no hint of what was actually meant.
#
# The cutoff is deliberately strict (0.82, plus a required margin over the
# runner-up) because the failure mode of guessing wrong is silent and bad: the
# agent would implement the task against an unrelated repo and could push a
# branch or open a PR there. A close-but-wrong typo should correct itself; a
# repo that plain doesn't exist under this org should stop and say so, not
# fall back to whatever happens to be least-dissimilar among 30 unrelated repos.
if ! gh api "repos/${GITHUB_ORG}/${REPO}" >/dev/null 2>&1; then
  CANDIDATES="$(gh repo list "$GITHUB_ORG" --limit 300 --json name -q '.[].name' 2>/dev/null || true)"
  RESULT="$(printf '%s\n' "$CANDIDATES" | python3 -c '
import sys, difflib
target = sys.argv[1]
candidates = [c.strip() for c in sys.stdin if c.strip()]
scored = sorted(
    ((difflib.SequenceMatcher(None, target, c).ratio(), c) for c in candidates),
    reverse=True,
)[:3]
CONFIDENT, MARGIN = 0.82, 0.10
if scored and scored[0][0] >= CONFIDENT and (len(scored) < 2 or scored[0][0] - scored[1][0] >= MARGIN):
    print("MATCH", scored[0][1])
else:
    print("NOMATCH", " ".join(f"{c}({r:.2f})" for r, c in scored))
' "$REPO")"
  read -r VERDICT REST <<<"$RESULT"
  if [ "$VERDICT" = "MATCH" ]; then
    log "repo '${REPO}' not found in ${GITHUB_ORG} — using closest match '${REST}' instead"
    REPO="$REST"
  else
    log "repo '${REPO}' not found in ${GITHUB_ORG} and no confident match — closest were: ${REST:-none}. Check the repo name and GITHUB_ORG."
    exit 1
  fi
fi

MIRROR="${CACHE_ROOT}/repos/${GITHUB_ORG}/${REPO}.git"
WORK="${CACHE_ROOT}/worktrees/${REPO}/${RUN_ID}"
LOCK="${CACHE_ROOT}/locks/${GITHUB_ORG}__${REPO}.lock"
LOGS="/work/logs/${RUN_ID}"
mkdir -p "$LOGS" "$(dirname "$MIRROR")" "$(dirname "$WORK")" "$(dirname "$LOCK")"

# The mirror is shared by every run of this repo, and its remote URL is stored
# token-free so a cached mirror outlives any one token. Auth comes from a
# credential file in this container's HOME instead — not from the URL (which
# would persist in the mirror's config) and not from `git -c http.extraheader`
# (which would show the token in `ps` output on a shared box).
git config --global credential.helper store
git config --global --add safe.directory '*'
umask 077
printf 'https://x-access-token:%s@github.com\n' "$GH_TOKEN" > "$HOME/.git-credentials"
umask 022

# --- derive a Deel-convention branch name -----------------------------------
# `sed`/`cut` work line by line: a task with embedded newlines (a pasted
# checklist, "fail-lint\npass-test\n...") would otherwise sail through with
# each line separately sedded and the newlines between them left intact,
# producing a "slug" that is itself multi-line — which git then rejects as a
# branch name with a bare `fatal:` and no indication why. `tr -s '[:space:]'
# ' '` collapses all whitespace, including newlines and tabs, to single
# spaces first, so everything below always sees one line.
slug=$(printf '%s' "$TASK" \
  | tr -s '[:space:]' ' ' \
  | tr '[:upper:]' '[:lower:]' \
  | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' \
  | cut -c1-40 | sed -E 's/-+$//')
BRANCH="${TICKET}-${slug}"

# Belt and suspenders: validate the branch name itself rather than letting a
# malformed one reach `git switch -c` as an opaque git error. If it's somehow
# still invalid (empty slug, a ticket id with characters git disallows in
# refs), fall back to a short, deterministic, always-valid name and say so
# plainly — repo, attempted name, and what's being used instead — so a failure
# here is something you can read at a glance, not a fatal to go dig through.
if ! git check-ref-format --branch "$BRANCH" >/dev/null 2>&1; then
  SAFE_BRANCH="${TICKET//[^A-Za-z0-9-]/-}-run-${RUN_ID##*-}"
  log "invalid branch name for repo=$REPO: '$BRANCH' — using '$SAFE_BRANCH' instead"
  BRANCH="$SAFE_BRANCH"
fi

log "run $RUN_ID | repo=$REPO base=$BASE_BRANCH branch=$BRANCH"

# --- 1. checkout -------------------------------------------------------------
# Every git operation that touches shared state in the mirror — creating it,
# fetching into it, adding or removing a worktree, creating a branch ref — runs
# while holding one per-repo lock. Parallel runs against the same repo therefore
# serialise for the seconds of git bookkeeping and then diverge into their own
# worktrees for the minutes of install, agent and validation.
if ! lock_acquire "$LOCK" "$LOCK_TIMEOUT"; then
  log "timed out after ${LOCK_TIMEOUT}s waiting for the ${REPO} lock"
  exit 1
fi

# On CACHE_BACKEND=fs this is today's cache-hit/cache-miss fetch-or-clone
# against the shared bind mount. On CACHE_BACKEND=s3 it seeds the mirror from
# a git bundle in CACHE_BUCKET first — see agent/lib/cache.sh.
cache_mirror_sync "$MIRROR" "$GITHUB_ORG" "$REPO" "https://github.com/${GITHUB_ORG}/${REPO}.git"

if ! git -C "$MIRROR" rev-parse --verify --quiet "refs/remotes/origin/${BASE_BRANCH}" >/dev/null; then
  log "base branch ${BASE_BRANCH} does not exist on ${GITHUB_ORG}/${REPO}"
  exit 1
fi

# Two prompts on the same ticket produce the same slug, and a slug already taken
# by a live run or by an earlier PR would fail `switch -c` or clobber someone
# else's branch. Suffix with the run id in that case. Both checks are local: the
# fetch above just refreshed refs/remotes/origin/*, so this costs no network
# round trip inside the lock.
if git -C "$MIRROR" show-ref --verify --quiet "refs/heads/${BRANCH}" \
  || git -C "$MIRROR" show-ref --verify --quiet "refs/remotes/origin/${BRANCH}"; then
  BRANCH="${BRANCH}-${RUN_ID##*-}"
  log "branch name taken — using $BRANCH"
fi

if ! git -C "$MIRROR" worktree add --quiet --detach "$WORK" "refs/remotes/origin/${BASE_BRANCH}"; then
  log "could not create worktree for repo=$REPO at $WORK (base=$BASE_BRANCH) — see git output above"
  exit 1
fi
cd "$WORK"
if ! git switch --quiet -c "$BRANCH"; then
  log "could not create branch '$BRANCH' for repo=$REPO in $WORK — see git output above"
  exit 1
fi

# Best-effort, while still holding the lock: hand the next run of this repo a
# warmer starting point. No-op on the fs backend, where the bind mount already
# did that for free.
cache_mirror_publish "$MIRROR" "$GITHUB_ORG" "$REPO"
lock_release "$LOCK"

log "branch=$BRANCH worktree=$WORK"

# The worktree lives in the shared cache so its recorded path is meaningful to
# every container — a `worktree prune` from a parallel run can then tell a live
# worktree from an abandoned one. Removing it is also shared-state bookkeeping,
# so it takes the lock too.
cleanup() {
  local code=$?
  if [ "$KEEP_WORKTREE" = "1" ]; then
    log "KEEP_WORKTREE=1 — leaving worktree at $WORK"
    return $code
  fi
  cd /work
  if lock_acquire "$LOCK" 120; then
    git -C "$MIRROR" worktree remove --force "$WORK" 2>/dev/null || rm -rf "$WORK"
    git -C "$MIRROR" worktree prune 2>/dev/null || true
    lock_release "$LOCK"
  else
    rm -rf "$WORK"
  fi
  return $code
}
trap cleanup EXIT

git config user.name  "${GIT_AUTHOR_NAME:-akai-agent}"
git config user.email "${GIT_AUTHOR_EMAIL:-akai-agent@deel.com}"

# --- 2. install --------------------------------------------------------------
# Detect the package manager from the target repo's lockfile rather than
# assuming pnpm, so this runner works against any repo, not just Deel's.
if [ -f pnpm-lock.yaml ]; then
  PKG_RUN="pnpm"
  INSTALL_CMD="pnpm install --frozen-lockfile"
  # Shared across runs, so the second run of a repo hardlinks instead of
  # downloading. pnpm takes its own locks inside the store.
  pnpm config set store-dir "${CACHE_ROOT}/pnpm-store"
elif [ -f package-lock.json ]; then
  PKG_RUN="npm run"
  INSTALL_CMD="npm ci"
elif [ -f yarn.lock ]; then
  PKG_RUN="yarn"
  INSTALL_CMD="yarn install --frozen-lockfile"
else
  PKG_RUN="npm run"
  INSTALL_CMD="npm install"
fi

LINT_CMD="${LINT_CMD:-$PKG_RUN lint}"
TEST_CMD="${TEST_CMD:-$PKG_RUN test}"
BUILD_CMD="${BUILD_CMD:-$PKG_RUN build}"
if [ -z "${TYPECHECK_CMD:-}" ]; then
  if node -e "process.exit(require('./package.json').scripts.typecheck ? 0 : 1)" 2>/dev/null; then
    TYPECHECK_CMD="$PKG_RUN typecheck"
  else
    TYPECHECK_CMD="npx tsc --noEmit"
  fi
fi

log "package manager: $PKG_RUN"

# On CACHE_BACKEND=s3, a lockfile-keyed node_modules tarball can skip the
# install command entirely — the single biggest time win available on a
# platform with a hard wall-clock ceiling. On CACHE_BACKEND=fs this is a
# permanent "miss": that backend already gets its speedup from the shared
# pnpm-store bind mount instead.
LOCKFILE=$(ls pnpm-lock.yaml package-lock.json yarn.lock 2>/dev/null | head -1)
DEPS_CACHE_STATUS=$(cache_deps_restore "$LOCKFILE" "$(pwd)/node_modules" "$REPO")
if [ "$DEPS_CACHE_STATUS" = "hit" ]; then
  log "deps cache hit — skipping $INSTALL_CMD"
  : > "$LOGS/install.log"
  echo "deps restored from cache; install skipped" >> "$LOGS/install.log"
else
  eval "$INSTALL_CMD" 2>&1 | tee "$LOGS/install.log"
  cache_deps_save "$LOCKFILE" "$(pwd)/node_modules" "$REPO"
fi

# --- 3. agent loop -----------------------------------------------------------
# The agent iterates on its own: edit, run lint/test, read the failure, fix.
# We do NOT trust its self-report — step 4 re-runs everything independently.
log "running agent"
report_state "running agent" "coding"
PROMPT=$(cat <<EOF
Task: ${TASK}

Jira ticket: ${TICKET}
Repository: ${GITHUB_ORG}/${REPO}
Branch: ${BRANCH} (already created from ${BASE_BRANCH}; you are on it)

Implement this change. After editing, run the validation commands yourself and
keep iterating until every one of them exits zero:

  ${LINT_CMD}
  ${TYPECHECK_CMD}
  ${TEST_CMD}
  ${BUILD_CMD}

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
  report_failed
  exit "$AGENT_EXIT"
fi

if git diff --quiet && git diff --cached --quiet; then
  log "agent produced no changes — stopping"
  report_failed
  exit 1
fi

# --- 4. independent validation gate -----------------------------------------
# This is the gate, not the agent's opinion. Any failure here blocks the PR.
log "validating"
report_state "validating" "validating"
: > "$LOGS/validation.log"
FAILED=""
for step in \
  "lint:${LINT_CMD}" \
  "typecheck:${TYPECHECK_CMD}" \
  "test:${TEST_CMD}" \
  "build:${BUILD_CMD}"
do
  name="${step%%:*}"; cmd="${step#*:}"
  printf '\n----- %s -----\n' "$name" >> "$LOGS/validation.log"
  if eval "$cmd" >> "$LOGS/validation.log" 2>&1; then
    echo "PASS $name"
    report_check "$name" "pass"
  else
    echo "FAIL $name"
    report_check "$name" "fail"
    FAILED="${FAILED} ${name}"
  fi
done

if [ -n "$FAILED" ]; then
  log "validation failed:${FAILED} — no PR opened. See $LOGS/validation.log"
  report_failed
  exit 1
fi

# --- 5. commit and PR, or hand off to a separate publish step ---------------
SUMMARY=$(head -c 2000 "$LOGS/agent-summary.txt")

if [ "$PUBLISH_MODE" = "deferred" ]; then
  # This branch never runs git push or gh — see docs/lambda-migration.md §4.6
  # step 11. That is the point: a task running with PUBLISH_MODE=deferred
  # need not hold a GitHub token capable of writing at all, which makes the
  # guardrail an IAM boundary instead of the DENIED-command blocklist in
  # agent.py being the only thing standing between the agent and a push.
  log "PUBLISH_MODE=deferred — writing patch instead of pushing"
  git add -A
  git diff --cached --binary > "$LOGS/patch.diff"

  jq -n \
    --arg run_id "$RUN_ID" --arg repo "$REPO" --arg org "$GITHUB_ORG" \
    --arg ticket "$TICKET" --arg task "$TASK" --arg branch "$BRANCH" \
    --arg base_branch "$BASE_BRANCH" --arg summary "$SUMMARY" \
    --arg lint "$LINT_CMD" --arg typecheck "$TYPECHECK_CMD" \
    --arg test "$TEST_CMD" --arg build "$BUILD_CMD" \
    '{run_id: $run_id, org: $org, repo: $repo, ticket: $ticket, task: $task,
      branch: $branch, base_branch: $base_branch, summary: $summary,
      checks: {lint: $lint, typecheck: $typecheck, test: $test, build: $build}}' \
    > "$LOGS/publish-meta.json"

  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN=1 — stopping before handoff. Patch at $LOGS/patch.diff"
    exit 0
  fi

  if [ -n "${CACHE_BUCKET:-}" ]; then
    aws s3 cp --quiet "$LOGS/patch.diff" "s3://${CACHE_BUCKET}/runs/${RUN_ID}/patch.diff"
    aws s3 cp --quiet "$LOGS/publish-meta.json" "s3://${CACHE_BUCKET}/runs/${RUN_ID}/meta.json"
    log "patch handed off to s3://${CACHE_BUCKET}/runs/${RUN_ID}/ — publish step takes it from here"
  else
    log "CACHE_BUCKET not set — patch left at $LOGS/patch.diff for manual pickup"
  fi

  report_state "awaiting publish" "awaiting_publish"

  log "done — logs at $LOGS (worktree removed unless KEEP_WORKTREE=1)"
  exit 0
fi

# PUBLISH_MODE=inline — today's EC2 behaviour, unchanged.
git add -A
git commit -m "feat: ${TASK}" -m "${TICKET}"

if [ "$DRY_RUN" = "1" ]; then
  log "DRY_RUN=1 — stopping before push. Worktree: $WORK"
  exit 0
fi

log "pushing and opening PR"
# Under the lock: a push writes to the mirror's config and ref store, which
# parallel runs share. No `-u` — nothing here reads the upstream afterwards.
if ! lock_acquire "$LOCK" "$LOCK_TIMEOUT"; then
  log "timed out after ${LOCK_TIMEOUT}s waiting for the ${REPO} lock to push"
  exit 1
fi
git push origin "refs/heads/${BRANCH}:refs/heads/${BRANCH}"
lock_release "$LOCK"

PR_URL=$(gh pr create \
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
| \`${LINT_CMD}\` | pass |
| \`${TYPECHECK_CMD}\` | pass |
| \`${TEST_CMD}\` | pass |
| \`${BUILD_CMD}\` | pass |

## Notes

Generated by the Akai coding agent (run \`${RUN_ID}\`). Needs human review before merge.

${TICKET}
EOF
)")
echo "$PR_URL"
report_pr "$PR_URL"

log "done — logs at $LOGS (worktree removed unless KEEP_WORKTREE=1)"
