#!/bin/sh
set -eu

CRAFT_USER="${CRAFT_USER:-craftagents}"
CRAFT_GROUP="${CRAFT_GROUP:-craftagents}"
CRAFT_HOME="${HOME:-/home/craftagents}"

log() { echo "[craft-agent-entrypoint] $*"; }

if [ "$(id -u)" -ne 0 ]; then
  if [ "$(id -un 2>/dev/null || true)" = "$CRAFT_USER" ]; then
    log "already running as $CRAFT_USER; skipping ownership migration"
    exec /app/bin/craft-server "$@"
  fi
  log "fatal: entrypoint must start as root to migrate volume ownership, or as $CRAFT_USER after ownership is already correct (current uid=$(id -u))"
  exit 1
fi

# Persistent Craft Agent state was originally written by the upstream bun user
# (uid/gid 1000).  The runtime now drops to the dedicated craftagents user
# (uid/gid 1007), so fix ownership of writable state before starting the
# server.  Keep this targeted so mounted working copies under /home/* are not
# recursively rewritten.
mkdir -p "$CRAFT_HOME" \
         "$CRAFT_HOME/.craft-agent" \
         "$CRAFT_HOME/.cache" \
         "$CRAFT_HOME/.config" \
         "$CRAFT_HOME/.config/gcloud" \
         "$CRAFT_HOME/.local" \
         "$CRAFT_HOME/.ssh" \
         "$CRAFT_HOME/.kube" \
         "$CRAFT_HOME/.aws"

# Only chown the home directory itself non-recursively.  Recursive chown of
# $CRAFT_HOME would cross into mounted working copies such as
# /home/craftagents/git/electinfo.
log "ensuring $CRAFT_HOME is owned by $CRAFT_USER:$CRAFT_GROUP"
chown "$CRAFT_USER:$CRAFT_GROUP" "$CRAFT_HOME" 2>/dev/null || \
  log "warning: unable to chown $CRAFT_HOME"

CHOWN_RECURSIVE_PATHS="${CRAFT_CHOWN_RECURSIVE_PATHS:-$CRAFT_HOME/.craft-agent $CRAFT_HOME/.cache $CRAFT_HOME/.config $CRAFT_HOME/.local $CRAFT_HOME/.ssh $CRAFT_HOME/.kube $CRAFT_HOME/.aws $CRAFT_HOME/.config/gcloud}"
if [ -n "${CRAFT_EXTRA_CHOWN_PATHS:-}" ]; then
  CHOWN_RECURSIVE_PATHS="$CHOWN_RECURSIVE_PATHS $CRAFT_EXTRA_CHOWN_PATHS"
fi

for path in $CHOWN_RECURSIVE_PATHS; do
  if [ -e "$path" ]; then
    log "ensuring $path is owned by $CRAFT_USER:$CRAFT_GROUP"
    chown -R "$CRAFT_USER:$CRAFT_GROUP" "$path" 2>/dev/null || \
      log "warning: unable to chown $path (possibly read-only bind mount)"
  fi
done

# Protect private SSH material when it is writable; read-only bind mounts may
# reject chmod and are safe to ignore.
chmod 700 "$CRAFT_HOME/.ssh" 2>/dev/null || true
chmod 600 "$CRAFT_HOME/.ssh"/* 2>/dev/null || true

# AWS CLI rejects credentials files with permissive modes; mirror the SSH
# treatment for ~/.aws.  Read-only bind mounts may reject chmod and are safe to
# ignore.
chmod 700 "$CRAFT_HOME/.aws" 2>/dev/null || true
chmod 600 "$CRAFT_HOME/.aws/credentials" 2>/dev/null || true
chmod 600 "$CRAFT_HOME/.aws/config" 2>/dev/null || true

# gcloud CLI is similarly strict about world-readable auth state; lock down
# ~/.config/gcloud and its application-default credentials JSON.
chmod 700 "$CRAFT_HOME/.config/gcloud" 2>/dev/null || true
chmod 600 "$CRAFT_HOME/.config/gcloud/application_default_credentials.json" 2>/dev/null || true

exec gosu "$CRAFT_USER:$CRAFT_GROUP" /app/bin/craft-server "$@"
