#!/usr/bin/env bash
#
# Container backup định kỳ: mỗi BACKUP_INTERVAL giây chạy 1 lần pg_dump và
# ghi file .dump ra /backups. /backups là CIFS volume trỏ tới thư mục trên
# máy thật Windows (xem docker-compose.yml + deploy/backup/README.md).
#
# Không dùng `set -e` cho vòng lặp chính: mỗi lần lỗi chỉ log rồi thử lại,
# container không được phép chết vì 1 lần dump hỏng.
set -uo pipefail

PGUSER="${PGUSER:-postgres}"
: "${POSTGRES_DB:?POSTGRES_DB is required}"
: "${POSTGRES_ADMIN_PASSWORD:?POSTGRES_ADMIN_PASSWORD is required}"
export PGPASSWORD="$POSTGRES_ADMIN_PASSWORD"

BACKUP_DIR="${BACKUP_DIR:-/backups}"
# Danh sách node Postgres để thử, cách nhau bằng khoảng trắng: "host:port host:port".
# 1 VM:  "pg-0:5432 pg-1:5432"      | Sau khi tách pg-1 sang VM2: "pg-0:5432 <VM2_IP>:5432"
PG_NODES="${PG_NODES:-pg-0:5432 pg-1:5432}"
BACKUP_INTERVAL="${BACKUP_INTERVAL:-21600}"   # 6 giờ
KEEP="${KEEP:-28}"                            # giữ 28 bản gần nhất (~1 tuần nếu 6h/lần)

log() { echo "$(date '+%F %T') [pg-backup] $*"; }

psql_q() { # host port sql  -> in kết quả 1 cột, im lặng nếu lỗi
  psql -h "$1" -p "$2" -U "$PGUSER" -d "$POSTGRES_DB" -tAqc "$3" 2>/dev/null
}

# Chọn node để dump: ưu tiên primary (pg_is_in_recovery = f),
# nếu không thấy primary thì lấy standby đầu tiên phản hồi được.
pick_node() {
  local node host port fallback=""
  for node in $PG_NODES; do
    host="${node%%:*}"; port="${node##*:}"
    case "$(psql_q "$host" "$port" 'SELECT pg_is_in_recovery()')" in
      f) echo "$host $port"; return 0 ;;
      t) [ -z "$fallback" ] && fallback="$host $port" ;;
    esac
  done
  [ -n "$fallback" ] && { echo "$fallback"; return 0; }
  return 1
}

do_backup() {
  local sel host port stamp tmp final
  sel="$(pick_node)" || { log "KHÔNG node Postgres nào phản hồi trong: $PG_NODES"; return 1; }
  read -r host port <<<"$sel"

  if ! mkdir -p "$BACKUP_DIR" 2>/dev/null || ! touch "$BACKUP_DIR/.wtest" 2>/dev/null; then
    log "KHÔNG ghi được vào $BACKUP_DIR — CIFS mount tới máy thật đang lỗi?"
    return 1
  fi
  rm -f "$BACKUP_DIR/.wtest"

  stamp="$(date +%F_%H%M%S)"
  tmp="$BACKUP_DIR/.${POSTGRES_DB}-${stamp}.dump.part"
  final="$BACKUP_DIR/${POSTGRES_DB}-${stamp}.dump"

  log "dump từ ${host}:${port} -> $(basename "$final")"
  if pg_dump -h "$host" -p "$port" -U "$PGUSER" -d "$POSTGRES_DB" \
       -Fc --no-owner --no-privileges > "$tmp"; then
    mv -f "$tmp" "$final"
    log "OK $(basename "$final") ($(du -h "$final" | cut -f1))"
  else
    rm -f "$tmp"
    log "pg_dump THẤT BẠI"
    return 1
  fi

  # Xoay vòng: chỉ giữ $KEEP bản .dump mới nhất trên máy thật.
  ls -1t "$BACKUP_DIR"/"${POSTGRES_DB}"-*.dump 2>/dev/null | tail -n +"$((KEEP + 1))" | while read -r old; do
    rm -f "$old" && log "xoá bản cũ $(basename "$old")"
  done
  return 0
}

# Cho phép chạy 1 lần rồi thoát:  docker exec library_pg_backup backup-loop.sh once
if [ "${1:-}" = "once" ]; then
  do_backup
  exit $?
fi

log "khởi động | interval=${BACKUP_INTERVAL}s keep=${KEEP} nodes='${PG_NODES}' dir=${BACKUP_DIR}"
while true; do
  do_backup || log "vòng backup gặp lỗi, thử lại sau ${BACKUP_INTERVAL}s"
  sleep "$BACKUP_INTERVAL"
done
