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

: "${BEDROCK_MODEL_ID:?BEDROCK_MODEL_ID must be set (see README step 1)}"
: "${AWS_REGION:?AWS_REGION must be set}"
: "${GH_TOKEN:?GH_TOKEN must be set}"
export BEDROCK_MODEL_ID AWS_REGION

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIRROR="${CACHE_ROOT}/repos/${GITHUB_ORG}/${REPO}.git"
WORK="${CACHE_ROOT}/worktrees/${REPO}/${RUN_ID}"
LOCK="${CACHE_ROOT}/locks/${GITHUB_ORG}__${REPO}.lock"
LOGS="/work/logs/${RUN_ID}"
mkdir -p "$LOGS" "$(dirname "$MIRROR")" "$(dirname "$WORK")" "$(dirname "$LOCK")"

log() { printf '\n=== %s ===\n' "$*"; }

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
slug=$(printf '%s' "$TASK" \
  | tr '[:upper:]' '[:lower:]' \
  | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' \
  | cut -c1-40 | sed -E 's/-+$//')
BRANCH="${TICKET}-${slug}"

log "run $RUN_ID | repo=$REPO base=$BASE_BRANCH"

# --- 1. checkout -------------------------------------------------------------
# Every git operation that touches shared state in the mirror — creating it,
# fetching into it, adding or removing a worktree, creating a branch ref — runs
# while holding one per-repo lock. Parallel runs against the same repo therefore
# serialise for the seconds of git bookkeeping and then diverge into their own
# worktrees for the minutes of install, agent and validation.
exec 9>"$LOCK"
if ! flock -w "$LOCK_TIMEOUT" 9; then
  log "timed out after ${LOCK_TIMEOUT}s waiting for the ${REPO} lock"
  exit 1
fi

if [ -d "$MIRROR" ]; then
  log "cache hit — fetching ${GITHUB_ORG}/${REPO}"
  git -C "$MIRROR" fetch --prune --quiet origin
else
  log "cache miss — mirroring ${GITHUB_ORG}/${REPO}"
  # Built up in a temp dir and moved into place, so an interrupted first clone
  # can never leave a half-populated mirror that later runs would treat as warm.
  tmp="${MIRROR}.incoming-${RUN_ID}"
  rm -rf "$tmp"
  git init --bare --quiet "$tmp"
  git -C "$tmp" remote add origin "https://github.com/${GITHUB_ORG}/${REPO}.git"
  # Fetch into refs/remotes/origin/* rather than refs/heads/*: refs/heads in the
  # mirror belongs to the per-run branches created below, so upstream branches
  # can never collide with a branch an agent is working on.
  git -C "$tmp" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  git -C "$tmp" fetch --prune --quiet origin
  mv "$tmp" "$MIRROR"
fi

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

git -C "$MIRROR" worktree add --quiet --detach "$WORK" "refs/remotes/origin/${BASE_BRANCH}"
cd "$WORK"
git switch --quiet -c "$BRANCH"

flock -u 9

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
  flock -w 120 "$LOCK" git -C "$MIRROR" worktree remove --force "$WORK" 2>/dev/null \
    || rm -rf "$WORK"
  flock -w 120 "$LOCK" git -C "$MIRROR" worktree prune 2>/dev/null || true
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
eval "$INSTALL_CMD" 2>&1 | tee "$LOGS/install.log"

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
  "lint:${LINT_CMD}" \
  "typecheck:${TYPECHECK_CMD}" \
  "test:${TEST_CMD}" \
  "build:${BUILD_CMD}"
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
# Under the lock: a push writes to the mirror's config and ref store, which
# parallel runs share. No `-u` — nothing here reads the upstream afterwards.
flock -w "$LOCK_TIMEOUT" "$LOCK" git push origin "refs/heads/${BRANCH}:refs/heads/${BRANCH}"

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
| \`${LINT_CMD}\` | pass |
| \`${TYPECHECK_CMD}\` | pass |
| \`${TEST_CMD}\` | pass |
| \`${BUILD_CMD}\` | pass |

## Notes

Generated by the Akai coding agent (run \`${RUN_ID}\`). Needs human review before merge.

${TICKET}
EOF
)"

log "done — logs at $LOGS (worktree removed unless KEEP_WORKTREE=1)"
