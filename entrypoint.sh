#!/bin/sh
# Boot the gbrain HTTP/MCP server against a brain on the persistent volume.
set -eu

DATA_DIR="${GBRAIN_HOME:-/data}"
BRAIN_REPO_DIR="${BRAIN_REPO_DIR:-$DATA_DIR/brain}"
PGLITE_PATH="$DATA_DIR/.gbrain/brain.pglite"

# --- persistence check -------------------------------------------------------
# ev learned this one expensively: if the data dir is not on a mount, every
# redeploy silently wipes everything while the service still looks healthy.
# Say so loudly at boot so it is visible in the Coolify log, not discovered later.
if mount | grep -q " ${DATA_DIR} "; then
  echo "data dir: $DATA_DIR (on a mount, persists across redeploys)"
else
  echo "data dir: $DATA_DIR -- EPHEMERAL, not on any mount; the brain WILL be wiped on redeploy"
fi

mkdir -p "$DATA_DIR"

# --- stale PGLite locks ------------------------------------------------------
# PGLite/GBrain records the serving process PID inside the persistent DB
# directory. In containers that PID is usually 1. After a crash/redeploy, the
# next entrypoint shell is also PID 1, so upstream sees "PID 1 is alive" and
# refuses to clear the old lock even though no gbrain server has opened the DB
# yet. Clear only locks that are clearly stale for this boot; leave locks held
# by any other live process alone.
clear_stale_pglite_locks() {
  [ -d "$PGLITE_PATH" ] || return 0

  lock_file="$PGLITE_PATH/.gbrain-lock/lock"
  if [ -f "$lock_file" ]; then
    lock_pid="$(sed -n 's/.*"pid":[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$lock_file" | head -n 1)"
    if [ -n "$lock_pid" ] && [ "$lock_pid" != "$$" ] && kill -0 "$lock_pid" 2>/dev/null; then
      echo "PGLite lock appears held by live PID $lock_pid; leaving it in place"
    else
      echo "clearing stale GBrain lock at $PGLITE_PATH/.gbrain-lock"
      rm -rf "$PGLITE_PATH/.gbrain-lock"
    fi
  fi

  postmaster_pid_file="$PGLITE_PATH/postmaster.pid"
  if [ -f "$postmaster_pid_file" ]; then
    postmaster_pid="$(head -n 1 "$postmaster_pid_file" 2>/dev/null || true)"
    case "$postmaster_pid" in
      ''|-*|*[!0-9]*)
        echo "clearing stale PGLite postmaster.pid"
        rm -f "$postmaster_pid_file"
        ;;
      *)
        if [ "$postmaster_pid" = "$$" ] || ! kill -0 "$postmaster_pid" 2>/dev/null; then
          echo "clearing stale PGLite postmaster.pid"
          rm -f "$postmaster_pid_file"
        else
          echo "PGLite postmaster appears live at PID $postmaster_pid; leaving postmaster.pid"
        fi
        ;;
    esac
  fi
}

clear_stale_pglite_locks

# --- git credentials ---------------------------------------------------------
# The brain repo is private. A read-only deploy key scoped to that single repo
# is the narrowest credential that works -- a PAT would carry access to every
# repo the issuing account can see, which is the wrong blast radius for a
# container that also talks to the public internet.
if [ -n "${BRAIN_DEPLOY_KEY:-}" ]; then
  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  # The key arrives as a single-line env var with \n escapes; restore them.
  printf '%b\n' "$BRAIN_DEPLOY_KEY" > /root/.ssh/id_ed25519
  chmod 600 /root/.ssh/id_ed25519
  ssh-keyscan -t ed25519 github.com > /root/.ssh/known_hosts 2>/dev/null
  chmod 644 /root/.ssh/known_hosts
  echo "deploy key installed for the brain repo"
fi

# --- brain content repo ------------------------------------------------------
# The markdown repo is the source of truth; the PGLite index is derived from it
# and can always be rebuilt with `gbrain sync`. Clone on first boot, fast-forward
# after. A pull failure is not fatal -- serving a slightly stale brain beats
# refusing to start.
if [ -n "${BRAIN_REPO_URL:-}" ]; then
  if [ -d "$BRAIN_REPO_DIR/.git" ]; then
    git -C "$BRAIN_REPO_DIR" pull --ff-only \
      || echo "warn: brain repo pull failed; continuing with the on-disk copy"
  else
    git clone "$BRAIN_REPO_URL" "$BRAIN_REPO_DIR" \
      || echo "warn: brain repo clone failed; starting with an empty brain"
  fi
else
  echo "warn: BRAIN_REPO_URL unset -- no markdown source of truth is attached"
fi

# --- init once ---------------------------------------------------------------
# The embedding model sizes the vector column, so it is fixed at init time.
# `gbrain config set embedding_model` is rejected upstream as a silent no-op --
# changing it later means wiping brain.pglite and re-importing. Pass it here or
# not at all.
if [ ! -e "$PGLITE_PATH" ]; then
  echo "no brain at $PGLITE_PATH -- initialising"
  gbrain init --pglite \
    --embedding-model "${GBRAIN_EMBEDDING_MODEL:-openai:text-embedding-3-small}"
else
  echo "existing brain found at $PGLITE_PATH"
fi

# Idempotent; also the documented recovery when a blocked postinstall leaves
# schema_version at 0.
gbrain apply-migrations --yes || echo "warn: apply-migrations failed"

# Search mode is a DB-plane field, so unlike the embedding model it is safe to
# reassert on every boot.
gbrain config set search.mode "${GBRAIN_SEARCH_MODE:-balanced}" \
  || echo "warn: could not set search.mode"

# Pull the markdown into the index. Safe on keyless brains: `embed --stale`
# exits 0 with a note when embeddings are disabled.
if [ -d "$BRAIN_REPO_DIR" ]; then
  gbrain sync --repo "$BRAIN_REPO_DIR" || echo "warn: initial sync failed"
  gbrain embed --stale || echo "warn: initial embed failed"
fi

# --- overnight maintenance ---------------------------------------------------
# PGLite holds an exclusive single-process lock, so `gbrain serve` and the CLI
# cannot both open the brain. That rules out the usual cron-alongside-server
# setup: the only safe window for maintenance is here, before serve starts.
# A nightly Coolify restart is what turns this block into the "nightly dream".
#
# Off by default: `dream` is LLM-bearing and bills per run. Turn it on with
# GBRAIN_DREAM_ON_BOOT=1 once an embedding/chat provider actually has credit,
# otherwise every boot burns ~a minute failing.
if [ "${GBRAIN_DREAM_ON_BOOT:-0}" = "1" ]; then
  echo "running overnight maintenance cycle"
  gbrain dream || echo "warn: dream cycle failed"
fi

# --- serve -------------------------------------------------------------------
# --public-url must match what clients actually hit, or OAuth discovery metadata
# advertises the wrong issuer and every client fails at the token step (RFC 8414).
#
# --bind is not optional in a container. Upstream changed the default bind to
# 127.0.0.1 in v0.34.1, so without this the server comes up healthy but listens
# on loopback only and the reverse proxy gets a connection refused -- which
# presents as a 502 with a clean application log. Verified 14 Aug 2026.
set -- serve --http --port "${GBRAIN_PORT:-3131}" --bind "${GBRAIN_BIND:-0.0.0.0}"
if [ -n "${GBRAIN_PUBLIC_URL:-}" ]; then
  set -- "$@" --public-url "$GBRAIN_PUBLIC_URL"
else
  echo "warn: GBRAIN_PUBLIC_URL unset -- OAuth discovery will advertise localhost"
fi

echo "starting: gbrain $*"
exec gbrain "$@"
