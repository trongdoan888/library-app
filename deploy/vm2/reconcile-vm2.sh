#!/usr/bin/env bash
# GitOps reconciler cho VM2 (chỉ chạy node standby pg-1).
#
# Mỗi tick: kéo origin/main mới nhất rồi `docker compose -f compose.vm2.yml up -d`
# để pg-1 luôn khớp khai báo trong repo. KHÔNG đụng gì tới pg-0/pgpool/app (những
# thứ đó do gitops agent trên VM1 lo).
set -euo pipefail

REPO_DIR="/home/trong/library-app"
LOG_TAG="gitops-agent-vm2"

log() {
  logger -t "$LOG_TAG" -- "$*" 2>/dev/null || true
  echo "[$LOG_TAG] $*"
}

cd "$REPO_DIR"

git fetch origin main --quiet

LOCAL_SHA=$(git rev-parse HEAD)
REMOTE_SHA=$(git rev-parse origin/main)

if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
  log "main updated: $LOCAL_SHA -> $REMOTE_SHA"
  git reset --hard origin/main --quiet
  git submodule sync --recursive --quiet || true
fi

# Drift correction: kéo pg-1 về đúng trạng thái khai báo, kể cả khi có người
# stop/xoá container bằng tay trên VM2.
docker compose -f compose.vm2.yml up -d --remove-orphans

log "reconcile complete"
