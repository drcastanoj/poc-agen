#!/usr/bin/env bash
# Per-repo lock, abstracted behind LOCK_BACKEND so run-agent.sh is identical on
# EC2 and on Fargate. See docs/lambda-migration.md §4.2 / §4.6 step 2.
#
#   LOCK_BACKEND=flock      (default) — today's behaviour: a bind-mounted file
#                            plus the kernel's advisory lock. Only correct when
#                            every run shares one filesystem.
#   LOCK_BACKEND=dynamodb   — a conditional put-item with a TTL, for Fargate
#                            tasks that don't share a disk. Requires
#                            LOCK_TABLE and an owner id unique per run.
#
# Public functions (both backends implement the same signature):
#   lock_acquire <key> <timeout_seconds>
#   lock_release <key>
#
# <key> is a filesystem path for the flock backend (its own lock file) and an
# arbitrary string for the dynamodb backend (used as the DynamoDB partition
# key) — callers pass the same $LOCK value either way and it works out.

LOCK_BACKEND="${LOCK_BACKEND:-flock}"

# --- flock backend -----------------------------------------------------------
# Unchanged from the original run-agent.sh. Bash functions run in the caller's
# shell (not a subshell), so the `exec` here opens FD 9 in run-agent.sh itself
# and it stays open until _flock_release or the process exits — exactly like
# the inline `exec 9>"$LOCK"` this replaces.
_flock_acquire() {
  local key="$1" timeout="$2"
  mkdir -p "$(dirname "$key")"
  exec 9>"$key"
  if ! flock -w "$timeout" 9; then
    return 1
  fi
}

_flock_release() {
  flock -u 9 2>/dev/null || true
}

# --- dynamodb backend ---------------------------------------------------------
# A conditional put-item stands in for the kernel lock: it succeeds only if no
# item exists for this key, or the existing item's TTL has already passed.
# The TTL is what a killed-mid-run Fargate task doesn't get for free — flock
# releases automatically when its holder's FD closes (including on SIGKILL);
# a DynamoDB item does not, so every lock in this backend carries an
# expiry and every caller must be willing to wait one out.
#
# LOCK_OWNER must be unique per run (the run id is used) so lock_release can't
# delete a lock some other, later run now holds.
_dynamodb_acquire() {
  local key="$1" timeout="$2"
  : "${LOCK_TABLE:?LOCK_TABLE must be set for LOCK_BACKEND=dynamodb}"
  : "${LOCK_OWNER:?LOCK_OWNER must be set for LOCK_BACKEND=dynamodb (use RUN_ID)}"
  : "${AWS_REGION:?}"
  local ttl="${LOCK_TTL_SECONDS:-900}"
  local deadline=$(( $(date +%s) + timeout ))
  local now
  while true; do
    now=$(date +%s)
    if aws dynamodb put-item \
        --region "$AWS_REGION" \
        --table-name "$LOCK_TABLE" \
        --item "{\"pk\":{\"S\":\"$key\"},\"owner\":{\"S\":\"$LOCK_OWNER\"},\"expires\":{\"N\":\"$((now + ttl))\"}}" \
        --condition-expression 'attribute_not_exists(pk) OR expires < :now' \
        --expression-attribute-values "{\":now\":{\"N\":\"$now\"}}" \
        >/dev/null 2>/tmp/lock-acquire.err; then
      return 0
    fi
    if grep -q ConditionalCheckFailedException /tmp/lock-acquire.err 2>/dev/null; then
      if [ "$now" -ge "$deadline" ]; then
        return 1
      fi
      sleep 2
      continue
    fi
    # Anything else (throttling, network) is a real error, not contention —
    # surface it instead of spinning silently for the full timeout.
    cat /tmp/lock-acquire.err >&2
    return 1
  done
}

_dynamodb_release() {
  local key="$1"
  : "${LOCK_TABLE:?}" "${LOCK_OWNER:?}" "${AWS_REGION:?}"
  # Conditioned on owner so a lock this run's TTL already lost to someone else
  # is never deleted out from under its new holder.
  aws dynamodb delete-item \
    --region "$AWS_REGION" \
    --table-name "$LOCK_TABLE" \
    --key "{\"pk\":{\"S\":\"$key\"}}" \
    --condition-expression 'owner = :o' \
    --expression-attribute-values "{\":o\":{\"S\":\"$LOCK_OWNER\"}}" \
    >/dev/null 2>&1 || true
}

# --- dispatch ------------------------------------------------------------------
lock_acquire() {
  case "$LOCK_BACKEND" in
    flock)    _flock_acquire "$@" ;;
    dynamodb) _dynamodb_acquire "$@" ;;
    *) echo "unknown LOCK_BACKEND: $LOCK_BACKEND" >&2; return 1 ;;
  esac
}

lock_release() {
  case "$LOCK_BACKEND" in
    flock)    _flock_release "$@" ;;
    dynamodb) _dynamodb_release "$@" ;;
    *) echo "unknown LOCK_BACKEND: $LOCK_BACKEND" >&2; return 1 ;;
  esac
}
