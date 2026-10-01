# End-to-End Test: Django → Docker → Filebeat → Elasticsearch → Kibana

Chạy trên VM1 sau khi đã `docker compose up -d` đủ backend + elasticsearch +
kibana + filebeat (xem `deploy/LOGGING.md`). Mỗi test: gọi API thật, rồi query
Elasticsearch để xác nhận log tới nơi — không tin bằng mắt trên Kibana UI, tin
bằng response JSON của `_search`.

```bash
A=$(grep ELASTIC_PASSWORD .env | cut -d= -f2)
search() { curl -s -u "elastic:$A" "http://localhost:9200/library-logs-*/_search" \
  -H 'content-type: application/json' -d "$1"; }
```

## TEST 1 — Login thành công
```bash
curl -s -X POST http://localhost:8000/api/token/ \
  -H 'content-type: application/json' -d '{"username":"<user_that_exists>","password":"<correct>"}'
sleep 2
search '{"query":{"bool":{"filter":[
  {"term":{"event.category":"authentication"}},
  {"term":{"event.action":"login"}},
  {"term":{"event.outcome":"success"}}
]}},"sort":[{"@timestamp":"desc"}],"size":1}'
```
Kỳ vọng: 1 hit, `username` đúng tài khoản vừa login, **không có field password/token nào**.

## TEST 2 — Login sai nhiều lần
```bash
for i in 1 2 3 4 5; do
  curl -s -X POST http://localhost:8000/api/token/ \
    -H 'content-type: application/json' -d '{"username":"<user>","password":"wrong"}' >/dev/null
done
sleep 2
search '{"query":{"term":{"event.action":"account_locked"}},"sort":[{"@timestamp":"desc"}],"size":1}'
```
Kỳ vọng: có event `account_locked`. Sau đó vào Kibana → Security → Alerts,
đợi tối đa 5 phút (interval của rule) → thấy alert "Brute-force login attempts".

## TEST 3-5 — Book CRUD
```bash
TOKEN=$(curl -s -X POST http://localhost:8000/api/token/ -H 'content-type: application/json' \
  -d '{"username":"<admin>","password":"<pass>"}' | grep -o '"access":"[^"]*' | cut -d'"' -f4)

ID=$(curl -s -X POST http://localhost:8000/api/book/ -H "Authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' -d '{"name":"E2E Test Book"}' \
  | grep -o '"id":"[^"]*' | head -1 | cut -d'"' -f4)
sleep 2
search "{\"query\":{\"bool\":{\"filter\":[{\"term\":{\"event.action\":\"create\"}},{\"term\":{\"resource_id\":\"$ID\"}}]}}}"

curl -s -X PUT http://localhost:8000/api/book/ -H "Authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' -d "{\"id\":\"$ID\",\"name\":\"E2E Test Book v2\"}" >/dev/null
sleep 2
search "{\"query\":{\"bool\":{\"filter\":[{\"term\":{\"event.action\":\"update\"}},{\"term\":{\"resource_id\":\"$ID\"}}]}}}"

curl -s -X DELETE http://localhost:8000/api/book/ -H "Authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' -d "{\"id\":\"$ID\"}" >/dev/null
sleep 2
search "{\"query\":{\"bool\":{\"filter\":[{\"term\":{\"event.action\":\"delete\"}},{\"term\":{\"resource_id\":\"$ID\"}}]}}}"
```
Mỗi bước kỳ vọng 1 hit với `resource:"Book"`, `resource_id` khớp `$ID`, `user`
là username của `<admin>`.

## TEST 6 — Gọi API không đủ quyền
```bash
USER_TOKEN=$(curl -s -X POST http://localhost:8000/api/token/ -H 'content-type: application/json' \
  -d '{"username":"<non_admin_user>","password":"<pass>"}' | grep -o '"access":"[^"]*' | cut -d'"' -f4)
curl -s -o /dev/null -w "%{http_code}\n" -X DELETE http://localhost:8000/api/book/ \
  -H "Authorization: Bearer $USER_TOKEN" -H 'content-type: application/json' -d '{"id":"x"}'
# kỳ vọng in ra 403
sleep 2
search '{"query":{"bool":{"filter":[{"term":{"event.category":"web"}},{"term":{"status":403}}]}},"sort":[{"@timestamp":"desc"}],"size":1}'
```
Kỳ vọng: access log có `status:403`, `method:"DELETE"`, `endpoint:"/api/book/"`.
Sau vài lần lặp lại (10+ trong 5 phút) → Kibana Alerts có "Repeated unauthorized/forbidden responses".

## TEST 7 — PostgreSQL log
```bash
docker exec library_pg0 sh -c 'tail -50 /opt/bitnami/postgresql/logs/*.log 2>/dev/null || echo "(bitnami log ra stdout, xem docker logs)"'
docker logs --tail 50 library_pg0
sleep 1
search '{"query":{"match_phrase":{"message":"database system is ready"}}}'
```
Kỳ vọng: log Postgres (dù không phải JSON) vẫn nằm trong `library-logs-*` qua
field `message`, tìm full-text được.

---

Nếu bất kỳ test nào 0 hit: kiểm tra theo thứ tự `docker logs backend` (log có
ra JSON không) → `docker logs library_filebeat` (có lỗi connect Elasticsearch
không) → `curl .../_cat/indices?v` (index `library-logs-*` có tồn tại và có
document không).
