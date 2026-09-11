#!/usr/bin/env bash
# GitOps reconciler for library-app.
#
# Run periodically (via the gitops-agent.timer systemd unit). On each tick:
#   1. Fetches the library-app repo and both submodules from origin/main.
#   2. If anything moved, updates the local checkout to match.
#   3. Rebuilds/restarts only the docker-compose services whose source
#      actually changed (backend and/or frontend) — and only if this VM's
#      compose file actually defines them.
#   4. Re-applies `docker compose up -d` unconditionally so any service a
#      human stopped/killed by hand on the VM gets healed back to the
#      state declared in the compose file (basic drift correction).
#
# Git is the source of truth; this script never pushes anything back to
# Git, it only ever reads from origin and reconciles local/container state
# to match it — that's what makes this "pull-based" GitOps rather than the
# previous CI-push model.
#
# Per-VM config via environment (set in the gitops-agent.service unit):
#   REPO_DIR      - checkout location        (default /home/trong/library-app)
#   COMPOSE_FILE  - which compose file this VM owns
#                     VM1: docker-compose.yml       (default)
#                     VM2: docker-compose.pg0.yml
#                     VM3: docker-compose.pg1.yml
set -euo pipefail

REPO_DIR="${REPO_DIR:-/home/trong/library-app}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
LOG_TAG="gitops-agent"

log() {
  logger -t "$LOG_TAG" -- "$*" 2>/dev/null || true
  echo "[$LOG_TAG] $*"
}

dc() { docker compose -f "$COMPOSE_FILE" "$@"; }

# Does COMPOSE_FILE define a service with this name?
has_service() { dc config --services 2>/dev/null | grep -qx "$1"; }

cd "$REPO_DIR"

git fetch origin main --quiet

LOCAL_SHA=$(git rev-parse HEAD)
REMOTE_SHA=$(git rev-parse origin/main)

BACKEND_BEFORE=$(git -C backend_library rev-parse HEAD)
FRONTEND_BEFORE=$(git -C frontend_library rev-parse HEAD)

if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
  log "library-app main updated: $LOCAL_SHA -> $REMOTE_SHA"
  git reset --hard origin/main --quiet
  git submodule sync --recursive --quiet
fi

# Always follow each submodule's own main branch tip (not just the SHA
# pinned in library-app's tree), matching the previous deploy.yml behavior
# of always deploying the latest main of backend_library/frontend_library.
git submodule update --init --recursive --remote --quiet

BACKEND_AFTER=$(git -C backend_library rev-parse HEAD)
FRONTEND_AFTER=$(git -C frontend_library rev-parse HEAD)

CHANGED=0

if has_service backend && [ "$BACKEND_BEFORE" != "$BACKEND_AFTER" ]; then
  log "backend_library changed: $BACKEND_BEFORE -> $BACKEND_AFTER, rebuilding"
  dc build backend
  dc up -d backend
  CHANGED=1
fi

if has_service frontend && [ "$FRONTEND_BEFORE" != "$FRONTEND_AFTER" ]; then
  log "frontend_library changed: $FRONTEND_BEFORE -> $FRONTEND_AFTER, rebuilding"
  dc build frontend
  dc up -d frontend
  CHANGED=1
fi

# Drift correction: bring any stopped/removed container back in line with
# the compose file, even if nothing changed in Git this tick.
dc up -d --remove-orphans

if [ "$CHANGED" = "1" ]; then
  docker image prune -f
fi

log "reconcile complete (file=$COMPOSE_FILE changed=$CHANGED)"
