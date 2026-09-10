#!/usr/bin/env bash
# Repo mirror + dependency cache, abstracted behind CACHE_BACKEND so
# run-agent.sh is identical on EC2 and on Fargate. See
# docs/lambda-migration.md §4.2 / §4.6 step 3.
#
#   CACHE_BACKEND=fs    (default) — today's behaviour: cache/repos is a bind
#                        mount shared by every run on the same box, so a bare
#                        mirror created once is just... there for the next run.
#   CACHE_BACKEND=s3    — Fargate tasks don't share a disk, so the mirror is
#                        seeded from a `git bundle` in S3 (one sequential read
#                        instead of a full clone) and the installed
#                        node_modules directory is restored whole from a
#                        tarball keyed on the lockfile hash — the biggest
#                        single time win available, because run-agent.sh
#                        skips the install command entirely on a cache hit
#                        instead of merely warming a shared store.
#                        Requires CACHE_BUCKET.
#
# Public functions (both backends implement the same signature):
#   cache_mirror_sync <mirror-dir> <org> <repo> <remote-url>
#       Ensures <mirror-dir> is a warm bare mirror with upstream branches
#       under refs/remotes/origin/*, ready for the worktree steps in
#       run-agent.sh. Idempotent — safe to call whether or not the mirror
#       already exists locally.
#   cache_mirror_publish <mirror-dir> <org> <repo>
#       Best-effort: hands the next run a warmer starting point. No-op on the
#       fs backend (the shared filesystem already *is* the cache).
#   cache_deps_restore <lockfile> <node_modules-dir>
#       Populates <node_modules-dir> whole from a tarball keyed on the
#       lockfile's hash. Prints "hit" or "miss" to stdout — on a hit,
#       run-agent.sh skips the install command entirely; on a miss (or on the
#       fs backend, which relies on the shared pnpm-store instead) it runs
#       install as before.
#   cache_deps_save <lockfile> <node_modules-dir>
#       Best-effort: uploads <node_modules-dir> back for the next run with
#       this lockfile hash. No-op on the fs backend — the shared pnpm-store
#       bind mount already gives the next run a warm install.

CACHE_BACKEND="${CACHE_BACKEND:-fs}"

# --- fs backend ----------------------------------------------------------
# Unchanged from the original run-agent.sh — moved here verbatim so both
# backends live behind one call site.
_fs_mirror_sync() {
  local mirror="$1" org="$2" repo="$3" remote_url="$4"
  if [ -d "$mirror" ]; then
    echo "cache hit — fetching ${org}/${repo}"
    git -C "$mirror" fetch --prune --quiet origin
  else
    echo "cache miss — mirroring ${org}/${repo}"
    local tmp="${mirror}.incoming-${RUN_ID}"
    rm -rf "$tmp"
    git init --bare --quiet "$tmp"
    git -C "$tmp" remote add origin "$remote_url"
    git -C "$tmp" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
    git -C "$tmp" fetch --prune --quiet origin
    mv "$tmp" "$mirror"
  fi
}

_fs_mirror_publish() { :; }  # the bind mount already persisted it

_fs_deps_restore() { echo "miss"; }  # cache/pnpm-store is already shared and warm
_fs_deps_save() { :; }

# --- s3 backend ------------------------------------------------------------
_s3_mirror_sync() {
  local mirror="$1" org="$2" repo="$3" remote_url="$4"
  : "${CACHE_BUCKET:?CACHE_BUCKET must be set for CACHE_BACKEND=s3}"
  local key="repos/${org}/${repo}.bundle"
  local tmp_bundle="/tmp/$$-${repo}.bundle"

  if [ -d "$mirror" ]; then
    echo "cache hit — local mirror present for ${org}/${repo} — fetching"
    git -C "$mirror" fetch --prune --quiet origin
    return 0
  fi

  git init --bare --quiet "$mirror"
  git -C "$mirror" remote add origin "$remote_url"
  git -C "$mirror" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'

  if aws s3api head-object --bucket "$CACHE_BUCKET" --key "$key" >/dev/null 2>&1; then
    echo "cache hit — seeding ${org}/${repo} from s3://${CACHE_BUCKET}/${key}"
    aws s3 cp --quiet "s3://${CACHE_BUCKET}/${key}" "$tmp_bundle"
    # Fetch FROM the bundle file as if it were a remote, using the same
    # refspec used for the real remote below — this reproduces the fs
    # backend's refs/remotes/origin/* layout instead of `git clone --bare`'s
    # refs/heads/*, which run-agent.sh does not expect.
    git -C "$mirror" fetch --quiet "$tmp_bundle" '+refs/heads/*:refs/remotes/origin/*'
    rm -f "$tmp_bundle"
    # The bundle can be arbitrarily stale; catch anything newer.
    git -C "$mirror" fetch --prune --quiet origin
  else
    echo "cache miss — no bundle at s3://${CACHE_BUCKET}/${key}, cloning ${org}/${repo}"
    git -C "$mirror" fetch --prune --quiet origin
  fi
}

_s3_mirror_publish() {
  local mirror="$1" org="$2" repo="$3"
  : "${CACHE_BUCKET:?}"
  if [ "${CACHE_SKIP_BUNDLE_REFRESH:-0}" = "1" ]; then
    return 0
  fi
  local key="repos/${org}/${repo}.bundle"
  local tmp_bundle="/tmp/$$-${repo}-out.bundle"
  # --all bundles every ref currently in the mirror, i.e. refs/remotes/origin/*
  # plus this run's own refs/heads/<branch> — harmless; the next run's fetch
  # from origin will fast-forward past it, and the branch ref is gone from
  # the mirror once run-agent.sh's cleanup removes the worktree that owned it.
  git -C "$mirror" bundle create "$tmp_bundle" --all --quiet 2>/dev/null || {
    echo "warning: bundle refresh failed for ${org}/${repo}; next run falls back to a slower fetch" >&2
    return 0
  }
  aws s3 cp --quiet "$tmp_bundle" "s3://${CACHE_BUCKET}/${key}" || \
    echo "warning: could not upload refreshed bundle for ${org}/${repo}" >&2
  rm -f "$tmp_bundle"
}

_s3_deps_key() {
  local lockfile="$1" repo="$2" hash
  hash=$(sha256sum "$lockfile" | cut -d' ' -f1)
  echo "deps/${repo}/${hash}.tar.zst"
}

_s3_deps_restore() {
  local lockfile="$1" node_modules="$2" repo="${3:?repo name required}"
  : "${CACHE_BUCKET:?}"
  [ -f "$lockfile" ] || { echo "miss"; return 0; }
  local key tmp
  key=$(_s3_deps_key "$lockfile" "$repo")
  if ! aws s3api head-object --bucket "$CACHE_BUCKET" --key "$key" >/dev/null 2>&1; then
    echo "miss"
    return 0
  fi
  tmp="/tmp/$$-deps.tar.zst"
  aws s3 cp --quiet "s3://${CACHE_BUCKET}/${key}" "$tmp" || { echo "miss"; return 0; }
  rm -rf "$node_modules"
  mkdir -p "$node_modules"
  if tar --zstd -xf "$tmp" -C "$node_modules"; then
    rm -f "$tmp"
    echo "hit"
  else
    rm -f "$tmp"
    rm -rf "$node_modules"
    echo "miss"
  fi
}

_s3_deps_save() {
  local lockfile="$1" node_modules="$2" repo="${3:?repo name required}"
  : "${CACHE_BUCKET:?}"
  [ -d "$node_modules" ] || return 0
  # Recomputed rather than passed from cache_deps_restore: run-agent.sh always
  # captures that call's stdout via $(...), which runs it in a subshell, so
  # anything it exported would be lost anyway. Hashing a lockfile is cheap.
  local key
  key=$(_s3_deps_key "$lockfile" "$repo")
  local tmp="/tmp/$$-deps-out.tar.zst"
  ( cd "$node_modules" && tar --zstd -cf "$tmp" . ) || { echo "warning: deps tar failed" >&2; return 0; }
  aws s3 cp --quiet "$tmp" "s3://${CACHE_BUCKET}/${key}" || \
    echo "warning: could not upload deps cache" >&2
  rm -f "$tmp"
}

# --- dispatch --------------------------------------------------------------
cache_mirror_sync() {
  case "$CACHE_BACKEND" in
    fs) _fs_mirror_sync "$@" ;;
    s3) _s3_mirror_sync "$@" ;;
    *) echo "unknown CACHE_BACKEND: $CACHE_BACKEND" >&2; return 1 ;;
  esac
}

cache_mirror_publish() {
  case "$CACHE_BACKEND" in
    fs) _fs_mirror_publish "$@" ;;
    s3) _s3_mirror_publish "$@" ;;
    *) echo "unknown CACHE_BACKEND: $CACHE_BACKEND" >&2; return 1 ;;
  esac
}

cache_deps_restore() {
  case "$CACHE_BACKEND" in
    fs) _fs_deps_restore "$@" ;;
    s3) _s3_deps_restore "$@" ;;
    *) echo "unknown CACHE_BACKEND: $CACHE_BACKEND" >&2; return 1 ;;
  esac
}

cache_deps_save() {
  case "$CACHE_BACKEND" in
    fs) _fs_deps_save "$@" ;;
    s3) _s3_deps_save "$@" ;;
    *) echo "unknown CACHE_BACKEND: $CACHE_BACKEND" >&2; return 1 ;;
  esac
}
