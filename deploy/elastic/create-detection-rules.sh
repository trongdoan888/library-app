#!/usr/bin/env bash
# Run once after `docker compose up -d` has elasticsearch/kibana healthy, to
# wire up the Elastic Security detection rules for this project's audit log
# (backend_library/api/audit.py, api/middleware.py, api/apps.py). Idempotent -
# a rule that already exists (matched by rule_id) just gets a 409, ignored.
#
# Usage: ELASTIC_PASSWORD=... ./deploy/elastic/create-detection-rules.sh
set -euo pipefail

KIBANA_URL="${KIBANA_URL:-http://localhost:5601}"
ELASTIC_PASSWORD="${ELASTIC_PASSWORD:?set ELASTIC_PASSWORD (same value as in .env)}"

curl -sf -u "elastic:${ELASTIC_PASSWORD}" -H 'kbn-xsrf: true' \
  -X POST "$KIBANA_URL/api/detection_engine/index" >/dev/null || true

create_rule() {
  echo "== $1 =="
  curl -s -u "elastic:${ELASTIC_PASSWORD}" -H 'kbn-xsrf: true' -H 'content-type: application/json' \
    -X POST "$KIBANA_URL/api/detection_engine/rules" -d "$2"
  echo
}

# 1. Authentication Monitoring - brute force
create_rule "brute-force login" '{
  "rule_id": "library-bruteforce-login",
  "name": "Brute-force login attempts",
  "description": "5+ failed logins for the same username within 5 minutes.",
  "type": "threshold",
  "language": "kuery",
  "query": "event.category:\"authentication\" and event.action:\"login\" and event.outcome:\"failure\"",
  "threshold": {"field": ["username"], "value": 5},
  "index": ["library-logs-*"],
  "from": "now-5m",
  "interval": "5m",
  "severity": "high",
  "risk_score": 73,
  "enabled": true
}'

# 1. Authentication Monitoring - lockout
create_rule "account locked" '{
  "rule_id": "library-account-locked",
  "name": "Account locked after repeated failed logins",
  "description": "The app-level lockout (5 failed attempts) tripped for an account.",
  "type": "query",
  "language": "kuery",
  "query": "event.category:\"authentication\" and event.action:\"account_locked\"",
  "index": ["library-logs-*"],
  "from": "now-5m",
  "interval": "5m",
  "severity": "medium",
  "risk_score": 47,
  "enabled": true
}'

# 2. Unauthorized Access - repeated 401/403 from the same IP
create_rule "unauthorized access burst" '{
  "rule_id": "library-unauthorized-burst",
  "name": "Repeated unauthorized/forbidden responses",
  "description": "10+ HTTP 401/403 responses from the same IP within 5 minutes - scanning or a broken/malicious client.",
  "type": "threshold",
  "language": "kuery",
  "query": "event.category:\"web\" and status:(401 or 403)",
  "threshold": {"field": ["ip"], "value": 10},
  "index": ["library-logs-*"],
  "from": "now-5m",
  "interval": "5m",
  "severity": "medium",
  "risk_score": 47,
  "enabled": true
}'

# 3. CRUD Monitoring - bulk delete by one actor
create_rule "bulk delete" '{
  "rule_id": "library-bulk-delete",
  "name": "Unusual bulk delete activity",
  "description": "One user deleted 10+ records within 5 minutes.",
  "type": "threshold",
  "language": "kuery",
  "query": "event.category:\"database\" and event.action:\"delete\"",
  "threshold": {"field": ["actor"], "value": 10},
  "index": ["library-logs-*"],
  "from": "now-5m",
  "interval": "5m",
  "severity": "high",
  "risk_score": 70,
  "enabled": true
}'

# 4. Audit Monitoring - any change to the User resource (accounts/roles)
create_rule "user resource change" '{
  "rule_id": "library-user-resource-change",
  "name": "User account created, updated or deleted",
  "description": "Any CRUD on the User model - account/role changes are rare enough that every one deserves a look, not just a burst.",
  "type": "query",
  "language": "kuery",
  "query": "event.category:\"database\" and resource:\"User\"",
  "index": ["library-logs-*"],
  "from": "now-5m",
  "interval": "5m",
  "severity": "medium",
  "risk_score": 47,
  "enabled": true
}'
