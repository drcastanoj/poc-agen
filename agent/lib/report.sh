#!/usr/bin/env bash
# Pushes coarse run state to DynamoDB so a stateless console (lambda/api) can
# poll it instead of tailing a live process's stdout — see
# docs/lambda-migration.md §4.5. No-op whenever RUN_TABLE is unset, so this is
# silent and free on EC2/local runs; every function here is best-effort and
# never fails the run over a transient DynamoDB error.
#
# The full, line-by-line log is NOT duplicated into DynamoDB — the awslogs
# driver already ships every line of container stdout to CloudWatch Logs, and
# lambda/api's getLog reads it from there. Writing here is only for the
# handful of state transitions the console's sidebar actually renders:
# phase/state, the four check verdicts, and (in PUBLISH_MODE=inline) the PR
# link. In PUBLISH_MODE=deferred the PR link is reported by lambda/publish
# instead, since this task never learns it.
#
# Public functions:
#   report_state <phase> <state>
#   report_check <name> <pass|fail>
#   report_pr <url>
#   report_failed [state]     defaults to "failed"

_report_enabled() { [ -n "${RUN_TABLE:-}" ] && [ -n "${RUN_ID:-}" ]; }

_report_update() {
  # $1 = --update-expression value, $2 = --expression-attribute-names json,
  # $3 = --expression-attribute-values json
  aws dynamodb update-item \
    --region "${AWS_REGION:?}" \
    --table-name "$RUN_TABLE" \
    --key "{\"id\":{\"S\":\"${RUN_ID}\"}}" \
    --update-expression "$1" \
    --expression-attribute-names "$2" \
    --expression-attribute-values "$3" \
    >/dev/null 2>&1 || true
}

report_state() {
  _report_enabled || return 0
  local phase="$1" state="$2"
  _report_update \
    'SET #ph = :p, #st = :s' \
    '{"#ph":"phase","#st":"state"}' \
    "$(jq -n --arg p "$phase" --arg s "$state" '{":p":{"S":$p},":s":{"S":$s}}')"
}

report_check() {
  _report_enabled || return 0
  local name="$1" verdict="$2"
  _report_update \
    'SET #ck.#n = :v' \
    "$(jq -n --arg n "$name" '{"#ck":"checks","#n":$n}')" \
    "$(jq -n --arg v "$verdict" '{":v":{"S":$v}}')"
}

report_pr() {
  _report_enabled || return 0
  local url="$1"
  _report_update \
    'SET prUrl = :u, #st = :s, endedAt = :t' \
    '{"#st":"state"}' \
    "$(jq -n --arg u "$url" --arg t "$(date +%s%3N)" \
      '{":u":{"S":$u},":s":{"S":"passed"},":t":{"N":$t}}')"
}

report_failed() {
  _report_enabled || return 0
  local state="${1:-failed}"
  _report_update \
    'SET #st = :s, endedAt = :t' \
    '{"#st":"state"}' \
    "$(jq -n --arg s "$state" --arg t "$(date +%s%3N)" '{":s":{"S":$s},":t":{"N":$t}}')"
}
