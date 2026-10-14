#!/usr/bin/env bash
# Gay cac su kien that de demo Logging & Security Monitoring (xem deploy/DEMO-LOGGING.md).
# Chay tren VM1, sau khi stack ELK + 9 detection rule da len.
#
#   ./deploy/elastic/demo-attacks.sh <kich-ban>
#   kich ban: login scan forbidden ssh sudoers ddl crud all verify
#
# Bien moi truong (co mac dinh, hoac doc tu .env):
#   VM1            IP/host nginx            (mac dinh localhost)
#   DEMO_USER      user bi khoa o "login"   (mac dinh demo_user)  - se bi khoa 30 phut!
#   USER2 / USER2_PASS   user thuong KHONG bi khoa, cho "forbidden"
#   ADMIN / ADMIN_PASS   admin, cho "crud"
#   ELASTIC_PASSWORD     cho "verify"
set -uo pipefail
cd "$(dirname "$0")/../.."
# Khong `source .env` (co ky tu dac biet lam bash loi cu phap): chi doc cac bien can dung.
for v in ELASTIC_PASSWORD POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB; do
  [ -n "${!v:-}" ] || export "$v=$(grep "^$v=" .env 2>/dev/null | cut -d= -f2-)"
done

VM1="${VM1:-localhost}"
BASE="http://$VM1"
DEMO_USER="${DEMO_USER:-demo_user}"
JSON='content-type: application/json'

token() { # token <user> <pass>
  curl -s -X POST "$BASE/api/token/" -H "$JSON" -d "{\"username\":\"$1\",\"password\":\"$2\"}" \
    | grep -o '"access":"[^"]*' | cut -d'"' -f4
}

login() { # 6 lan sai: lan 5 -> account_locked, lan 6 -> du nguong brute-force
  echo "== login: 6 lan sai mat khau cua '$DEMO_USER' (se bi khoa 30 phut)"
  for i in 1 2 3 4 5 6; do
    printf '%s ' "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/token/" -H "$JSON" \
      -d "{\"username\":\"$DEMO_USER\",\"password\":\"sai\"}")"
  done; echo
}

scan() { # >=20 lan 404 cung IP
  echo "== scan: 25 request toi duong dan khong ton tai"
  for i in $(seq 25); do curl -s -o /dev/null "$BASE/nope$i"; done; echo done
}

forbidden() { # >=10 lan 403 cung IP
  : "${USER2:?set USER2 va USER2_PASS (user thuong, khong bi khoa)}"
  local t; t=$(token "$USER2" "${USER2_PASS:?}")
  [ -n "$t" ] || { echo "khong lay duoc token cua $USER2"; return 1; }
  echo "== forbidden: 12 lan DELETE /api/book/ bang user thuong (ky vong 403)"
  for i in $(seq 12); do
    printf '%s ' "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "$BASE/api/book/" \
      -H "Authorization: Bearer $t" -H "$JSON" -d '{"id":"x"}')"
  done; echo
}

ssh_fail() { # >=5 lan sai cung src_ip
  echo "== ssh: 6 lan sai mat khau toi $VM1"
  for i in 1 2 3 4 5 6; do
    ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o NumberOfPasswordPrompts=1 \
        fake@"$VM1" true </dev/null 2>/dev/null
  done; echo done
}

sudoers() {
  echo "== sudoers: touch /etc/sudoers (auditd key lib_audit)"
  sudo touch /etc/sudoers && sudo ausearch -k lib_audit 2>/dev/null | tail -3
}

ddl() {
  echo "== ddl: CREATE/DROP TABLE truc tiep qua pgpool (khong qua app)"
  docker exec -e PGPASSWORD="${POSTGRES_PASSWORD:?}" library_pgpool \
    psql -h localhost -U "${POSTGRES_USER:?}" "${POSTGRES_DB:?}" \
    -c "CREATE TABLE zz_audit_test(i int); DROP TABLE zz_audit_test;"
}

crud() { # create -> update -> delete 1 Book, de co log database + changes
  : "${ADMIN:?set ADMIN va ADMIN_PASS}"
  local t id; t=$(token "$ADMIN" "${ADMIN_PASS:?}")
  [ -n "$t" ] || { echo "khong lay duoc token admin"; return 1; }
  echo "== crud: tao, sua, xoa 1 Book"
  id=$(curl -s -X POST "$BASE/api/book/" -H "Authorization: Bearer $t" -H "$JSON" \
        -d '{"name":"Demo Book"}' | grep -o '"id":"[^"]*' | head -1 | cut -d'"' -f4)
  echo "id=$id"
  curl -s -o /dev/null -X PUT "$BASE/api/book/" -H "Authorization: Bearer $t" -H "$JSON" \
    -d "{\"id\":\"$id\",\"name\":\"Demo Book v2\"}"
  curl -s -o /dev/null -X DELETE "$BASE/api/book/" -H "Authorization: Bearer $t" -H "$JSON" \
    -d "{\"id\":\"$id\"}"
}

verify() { # dem so document theo tung kich ban (15 phut gan nhat)
  : "${ELASTIC_PASSWORD:?set ELASTIC_PASSWORD}"
  local q
  count() { # count <ten> <query_string>
    local esc=${2//\"/\\\"}
    q=$(curl -s -u "elastic:$ELASTIC_PASSWORD" "localhost:9200/library-logs-*/_count" -H "$JSON" \
      -d "{\"query\":{\"bool\":{\"filter\":[{\"range\":{\"@timestamp\":{\"gte\":\"now-15m\"}}},{\"query_string\":{\"query\":\"$esc\"}}]}}}" \
      | grep -o '"count":[0-9]*' | cut -d: -f2)
    printf '%-28s %s\n' "$1" "${q:-?}"
  }
  count "login failure"      'event.category:authentication AND event.outcome:failure'
  count "account_locked"     'event.action:account_locked'
  count "nginx 404"          'app:nginx AND status:404'
  count "403 (access)"       'event.category:web AND status:403'
  count "CRUD (database)"    'event.category:database'
  count "ssh Failed"         'log_source:host_auth AND ssh_result:Failed'
  count "auditd lib_audit"   'log_source:host_audit AND audit_key:lib_audit'
  count "pgaudit AUDIT"      'message:"AUDIT" AND audit_class:*'
  echo "(so 0 -> xem muc 'Khi co su co' trong deploy/DEMO-LOGGING.md)"
}

case "${1:-}" in
  login) login ;;
  scan) scan ;;
  forbidden) forbidden ;;
  ssh) ssh_fail ;;
  sudoers) sudoers ;;
  ddl) ddl ;;
  crud) crud ;;
  verify) verify ;;
  all) login; scan; forbidden; ssh_fail; sudoers; ddl; crud
       echo; echo "Doi ~5 phut roi mo Kibana > Security > Alerts. Kiem tra log: $0 verify" ;;
  *) sed -n '2,12p' "$0"; exit 1 ;;
esac
