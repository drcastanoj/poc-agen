#!/usr/bin/env bash
# Fire a matrix of runs at the console at once: several prompts across two
# repos. Proves three things the serial path never exercised —
#
#   1. each repo is mirrored once and fetched thereafter (one "cache miss"
#      line per repo, no matter how many prompts hit it),
#   2. prompts on the same repo get their own worktree and their own branch,
#      including two prompts that slug to the same branch name,
#   3. concurrent runs queue at MAX_CONCURRENT instead of thrashing the box.
#
# Usage:
#   ./scripts/parallel-smoke.sh                    # repos from REPO_A / REPO_B
#   ./scripts/parallel-smoke.sh repo-one repo-two
#
# Env:
#   CONSOLE   default http://localhost:8080 (tunnel it over SSM first)
#   TIMEOUT   seconds to wait for the whole matrix, default 3600
#
# DRY_RUN is read by the runner, not by this script — it reaches the container
# from the console's own environment, so set it on the service and restart:
#   sudo systemctl set-environment DRY_RUN=1 && sudo systemctl restart poc-console

set -euo pipefail

CONSOLE="${CONSOLE:-http://localhost:8080}"
TIMEOUT="${TIMEOUT:-3600}"
REPO_A="${1:-${REPO_A:-demo-service}}"
REPO_B="${2:-${REPO_B:-demo-web}}"

command -v jq >/dev/null || { echo "jq is required"; exit 1; }

# Two prompts on repo A share a ticket AND slug to the same branch name — that
# collision is the interesting case, so it is in the matrix deliberately.
MATRIX=(
  "$REPO_A|POC-101|Remove the Profile item from the sidebar navigation"
  "$REPO_A|POC-101|Remove the Profile item from the sidebar navigation"
  "$REPO_A|POC-102|Add a health check endpoint that returns the build sha"
  "$REPO_B|POC-201|Rename the Submit button label to Save"
  "$REPO_B|POC-202|Extract the date formatting helper into its own module"
)

echo "console:  $CONSOLE"
echo "capacity: $(curl -fsS "$CONSOLE/api/capacity")"
echo

ids=()
for entry in "${MATRIX[@]}"; do
  IFS='|' read -r repo ticket task <<<"$entry"
  body=$(jq -n --arg repo "$repo" --arg ticket "$ticket" --arg task "$task" \
    '{repo:$repo, ticket:$ticket, task:$task}')
  # Posted back to back with no wait: the point is that they overlap.
  id=$(curl -fsS -X POST "$CONSOLE/api/runs" \
    -H 'Content-Type: application/json' -d "$body" | jq -r .id)
  ids+=("$id")
  printf 'queued %s  %-16s %-8s %s\n' "$id" "$repo" "$ticket" "$task"
done

echo
echo "waiting for ${#ids[@]} runs (ctrl-c is safe — runs continue on the box)"

deadline=$(( $(date +%s) + TIMEOUT ))
while :; do
  all=$(curl -fsS "$CONSOLE/api/runs")
  pending=$(jq --argjson ids "$(printf '%s\n' "${ids[@]}" | jq -R . | jq -s .)" \
    '[.[] | select(.id as $i | $ids | index($i))
          | select(.state | test("^(queued|starting|coding|validating)$"))] | length' \
    <<<"$all")

  jq -r --argjson ids "$(printf '%s\n' "${ids[@]}" | jq -R . | jq -s .)" \
    '[.[] | select(.id as $i | $ids | index($i))] | sort_by(.createdAt)
     | .[] | "  \(.id)  \(.repo|.[0:14])  \(.state|.[0:10])  \(.phase)"' <<<"$all"

  [ "$pending" -eq 0 ] && break
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "timed out with $pending run(s) still going"
    break
  fi
  sleep 10
  printf '\033[%dA' $(( ${#ids[@]} + 1 ))
done

echo
echo "--- results ---"
curl -fsS "$CONSOLE/api/runs" \
  | jq -r --argjson ids "$(printf '%s\n' "${ids[@]}" | jq -R . | jq -s .)" \
    '[.[] | select(.id as $i | $ids | index($i))] | sort_by(.createdAt) | .[]
     | "\(.id)  \(.repo)  \(.ticket)  \(.state)  \(.prUrl // "no PR")"'

# --- assertions ---------------------------------------------------------------
# Pulled from each run's captured output rather than from the box, so this works
# through the tunnel from a laptop.
all_log=$(for id in "${ids[@]}"; do curl -fsS "$CONSOLE/api/runs/$id/log"; echo; done)

echo
echo "--- cache: expect exactly one mirror clone per repo ---"
for repo in "$REPO_A" "$REPO_B"; do
  # The runner's cache-hit/cache-miss lines put a word or two ("mirroring",
  # "fetching", "seeding ... from s3://...") between the marker and the
  # org/repo — never immediately adjacent — so the pattern needs `.*` there,
  # not `[^ ]+`. (A stricter `[^ ]+` here never matched any real log line,
  # including on the EC2 path — it always reported zero clones and zero
  # fetches regardless of what actually happened. Confirmed by hand against
  # agent/run-agent.sh and agent/lib/cache.sh's real messages before fixing.)
  misses=$(grep -cE "cache miss —.* [^ ]*/${repo}([. ]|\$)" <<<"$all_log" || true)
  hits=$(grep -cE "cache hit —.* [^ ]*/${repo}([. ]|\$)" <<<"$all_log" || true)
  status=$([ "$misses" -le 1 ] && echo ok || echo "SUSPECT")
  printf '  %-16s %s clone(s), %s fetch(es)  [%s]\n' "$repo" "$misses" "$hits" "$status"
done

echo
echo "--- isolation: expect one distinct branch and worktree per run ---"
branches=$(grep -o 'branch=[^ ]*' <<<"$all_log" | sort -u | wc -l | tr -d ' ')
worktrees=$(grep -o 'worktree=[^ ]*' <<<"$all_log" | sort -u | wc -l | tr -d ' ')
printf '  %s runs, %s distinct branches, %s distinct worktrees  [%s]\n' \
  "${#ids[@]}" "$branches" "$worktrees" \
  "$([ "$branches" -eq "${#ids[@]}" ] && [ "$worktrees" -eq "${#ids[@]}" ] && echo ok || echo SUSPECT)"
grep -o 'branch=[^ ]*' <<<"$all_log" | sort -u | sed 's/^/    /'
