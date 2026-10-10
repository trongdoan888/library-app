# Logging & Security Monitoring (ELK)

Chuỗi: Django (Application/Access/Auth/Audit/CRUD log JSON ra stdout) → Docker
log driver → Filebeat → **Logstash** → Elasticsearch → Kibana → Elastic
Security detection rules → alert → dashboard. PostgreSQL (pg-0/pg-1/pg-witness)
cũng nằm trong pipeline (xem "VM2/VM3" bên dưới).

**ELK đúng nghĩa** (không chỉ "EK"): Filebeat không gửi thẳng tới Elasticsearch
nữa mà gửi qua giao thức beats tới Logstash (`deploy/logstash/logstash.conf`,
cổng 5044), Logstash mới là thành phần nói chuyện với Elasticsearch. Không có
filter nào ở Logstash — Filebeat đã parse JSON trước khi gửi — nên đây chỉ là
1 trạm trung chuyển, nhưng đúng vai trò "L" trong ELK.

Elasticsearch + Kibana chỉ chạy **1 nơi duy nhất: VM1** (`docker-compose.yml`).
VM2 (pg-0) và VM3 (pg-1) mỗi máy chạy thêm 1 Filebeat riêng, gửi log qua LAN
về Elasticsearch trên VM1 — vì Docker log của 1 container chỉ đọc được từ máy
vật lý đang chạy nó (`/var/lib/docker/containers` là local disk), không có
Filebeat trung tâm nào "nhìn xuyên" 3 VM được.

## Yêu cầu trước khi chạy

- **RAM VM1**: Elasticsearch (~1GB thực tế dù đặt heap 512m) + Logstash (~500MB,
  heap đặt 256m) + Kibana (~1GB) + Filebeat (~100MB) cộng thêm vào VM1 vốn đã
  chạy pgpool/witness/pgadmin/backend/frontend. Khuyến nghị VM1 có **≥ 8GB RAM**;
  thiếu RAM thì `elasticsearch` bị OOM-killed đầu tiên (`docker compose logs elasticsearch`).
- Trên VM1, set trước khi `up` (Elasticsearch cần, không set sẽ crash-loop
  `max virtual memory areas vm.max_map_count too low`):
  ```bash
  sudo sysctl -w vm.max_map_count=262144
  echo 'vm.max_map_count=262144' | sudo tee -a /etc/sysctl.conf
  ```
- **Firewall VM1**: mở cổng 5044 cho LAN (giống cách 5432 đã mở ở HA-3VM.md
  mục 0.4) để Filebeat trên VM2/VM3 gửi log tới Logstash được; cổng 9200 chỉ
  cần mở nếu muốn gọi API Elasticsearch trực tiếp từ xa (không bắt buộc cho
  pipeline log hoạt động, vì Filebeat giờ không nói chuyện thẳng với ES nữa):
  ```bash
  sudo ufw allow from 192.168.111.0/24 to any port 5044 proto tcp
  sudo ufw allow from 192.168.111.0/24 to any port 9200 proto tcp
  ```
- `.env` (cùng 1 bản, copy sang cả 3 VM như đang làm) cần thêm
  `ELASTIC_PASSWORD` và `KIBANA_PASSWORD` (xem `.env.example`).

## Dựng stack

**VM1:**
```bash
docker compose up -d elasticsearch
docker compose logs -f elasticsearch   # chờ "started"
docker compose up -d es-setup kibana logstash
docker compose logs -f logstash        # chờ "Pipelines running"
docker compose up -d filebeat
curl -s -u elastic:$ELASTIC_PASSWORD http://localhost:9200/_cluster/health
# Kibana: http://<VM1_IP>:5601  (đăng nhập elastic / $ELASTIC_PASSWORD)
```

**VM2 (pg0) và VM3 (pg1)** — sau khi VM1 đã lên và cổng 5044 đã mở:
```bash
cd ~/library-app
docker compose -f docker-compose.pg0.yml up -d filebeat   # đổi .pg1.yml trên VM3
docker compose -f docker-compose.pg0.yml logs -f filebeat # không còn báo lỗi connect refused là OK
```

## Tạo detection rules (1 lần, chạy từ VM1 hoặc máy có curl tới Kibana)

```bash
ELASTIC_PASSWORD=$(grep ELASTIC_PASSWORD .env | cut -d= -f2) \
  ./deploy/elastic/create-detection-rules.sh
```

5 rule trong Kibana → Security → Alerts (mapping với mục X của đề bài):
- **Brute-force login attempts** — Authentication Monitoring: 5+ login thất
  bại cùng username / 5 phút.
- **Account locked after repeated failed logins** — Authentication Monitoring.
- **Repeated unauthorized/forbidden responses** — Unauthorized Access: 10+
  HTTP 401/403 cùng IP / 5 phút.
- **Unusual bulk delete activity** — CRUD Monitoring: 1 user xoá 10+ record / 5 phút.
- **User account created/updated/deleted** — Audit Monitoring: mọi thay đổi
  trên model `User` (không cần ngưỡng, tài khoản/role thay đổi vốn hiếm).

Một alert kích hoạt = 1 sự kiện cần xem lại, không tự kết luận là tấn công
(đúng mục X).

## Log hạ tầng host (authen + audit)

Log app (Access/CRUD) chỉ là lớp ứng dụng; hạ tầng cần thêm log của **chính
máy host**. Filebeat (cả 3 VM) mount `/var/log` của host → `/host/var/log` và
đọc thêm 2 nguồn, gắn field `log_source`:

- `host_auth` — `/var/log/auth.log` (Ubuntu/Debian) hoặc `/var/log/secure`: SSH
  login/fail, sudo, su.
- `host_audit` — `/var/log/audit/audit.log` (auditd): ai sửa file/user/sudoers, exec.

Cài auditd trên **mỗi VM** (1 lần), file chưa có thì input chỉ nằm chờ:
```bash
sudo apt install -y auditd
echo '-w /etc/passwd -p wa -k lib_audit
-w /etc/shadow -p wa -k lib_audit
-w /etc/sudoers -p wa -k lib_audit
-w /etc/ssh/sshd_config -p wa -k lib_audit
-w /var/run/docker.sock -p rw -k lib_audit' | sudo tee /etc/audit/rules.d/library.rules
sudo augenrules --load
```
Kibana: `log_source: host_auth and message: "Failed password"` = brute-force SSH.
Rule `library-host-ssh-bruteforce` và `library-host-sensitive-file` (key `lib_audit`) trong `create-detection-rules.sh` bám vào 2 nguồn này.

### Audit DB (pgaudit) và nginx

- pg-0/pg-1 bật `POSTGRESQL_PGAUDIT_LOG=ddl,role` (image bitnami có sẵn pgaudit):
  mọi CREATE/ALTER/DROP và GRANT/CREATE ROLE ra stdout dạng `AUDIT: SESSION,...`,
  kể cả khi vào thẳng DB không qua app. Rule `library-db-ddl-role`. Kiểm tra sau
  khi `up -d` lại: `docker exec library_pg0 psql -U postgres -c "SHOW shared_preload_libraries"`
  phải có `pgaudit`. Không bật `write`/`read` (quá ồn, lộ giá trị) và không bật
  `log_connections` (health check pgpool 10s/lần).
- Rule `library-nginx-scan`: 20+ HTTP 404 / IP / 5 phút.
- Retention: `es-setup` tạo ILM policy `library-logs` (xóa index sau 30 ngày) +
  index template chỉ chứa setting lifecycle (không mapping, nên không lặp lại lỗi
  ECS). Chỉ áp cho index tạo SAU khi es-setup chạy; index cũ xóa tay.

### Kiểm thử end-to-end (chạy sau khi deploy, đây là bước chưa ai chạy)

```bash
# VM bất kỳ: authen
for i in 1 2 3 4 5 6; do ssh -o PreferredAuthentications=password fake@localhost true; done
# audit file nhạy cảm
sudo touch /etc/sudoers && sudo auditctl -l | grep lib_audit
# DB audit (VM1, qua pgpool)
docker exec -e PGPASSWORD=$POSTGRES_PASSWORD library_pgpool psql -h localhost -U $POSTGRES_USER $POSTGRES_DB -c "CREATE TABLE zz_audit_test(i int); DROP TABLE zz_audit_test;"
# nginx scan
for i in $(seq 25); do curl -s -o /dev/null http://localhost/nope$i; done
```
Kibana Discover (`library-logs-*`): `log_source:host_auth`, `log_source:host_audit`,
`message:AUDIT`, `app:nginx and status:404`; sau ≤5 phút Security → Alerts phải
có 4 rule tương ứng. Chạy lại `create-detection-rules.sh` để nạp rule mới.

## Cấu trúc field trong log (để build Discover/Dashboard)

Từ `backend_library/api/logging_json.py` + `api/audit.py`:

| Field | Ý nghĩa |
|---|---|
| `@timestamp`, `level`, `app`, `logger` | chuẩn, `app` luôn `"backend"` (đặt tên `app` không phải `service` vì ECS khóa `service` là object, xem ghi chú dưới) |
| `event.category` | `authentication` \| `web` \| `database` |
| `event.action` | `login` \| `account_locked` \| `token_refresh` \| `http_request` \| `create`\|`update`\|`delete` |
| `event.outcome` | `success` \| `failure` |
| `actor`, `user_id` | actor đang đăng nhập tại thời điểm log (JWT auth) — tên `actor` không phải `user` vì lý do tương tự `app`/`service` |
| `username` | (chỉ ở event login) tài khoản đang thử đăng nhập — khác `actor` vì lúc đó chưa auth xong |
| `method`, `endpoint`, `status`, `duration_ms`, `ip` | Access log (mọi request) |
| `resource`, `resource_id` | Audit/CRUD log — tên model + pk, **không** log giá trị field |
| `message` | log dạng string thường (Django `django.request`/`django.security`, không phải JSON) |

Log của postgres/pgpool/pgadmin không phải JSON nên rơi vào field `message`
(full-text search được trong Discover, không tách field).

**Không bao giờ xuất hiện trong log**: password, JWT access/refresh token,
`DJANGO_SECRET_KEY`, DB password, API key — xác nhận bằng `grep log_event
api/view/login.py` (chỉ truyền `username`, không truyền credential nào) và
self-test `JsonFormatter` (field `extra` của LogRecord — nơi Django có thể gắn
`request` object — không bao giờ được đọc).

## Sự cố thật đã gặp khi deploy (để tránh lặp lại)

- **Field tên trùng với ECS reserved object → Elasticsearch từ chối cả document
  (HTTP 400), Filebeat âm thầm drop, không có gì trong log app báo lỗi.**
  Gặp với `service` (đổi thành `app`) và `user` (đổi thành `actor`). ECS định
  nghĩa cả hai là **object** (`service.name`, `user.name`...); gửi lên dạng
  string phẳng → `document_parsing_exception`. Cách phát hiện: gửi thẳng 1
  dòng log thật (copy nguyên văn từ `docker compose logs backend`) vào
  Elasticsearch bằng `curl -X POST .../_doc`, đọc thẳng lỗi trả về — đừng đoán
  qua Kibana UI hay log Filebeat (Filebeat chỉ in "Cannot index event
  (status=400): dropping event!" không kèm lý do chi tiết). Trước khi thêm field
  mới vào `log_event()`, tránh các tên ECS hay dùng dưới dạng object:
  `event`, `service`, `user`, `host`, `agent`, `container`, `log`, `error`,
  `http`, `url`, `process`, `network`.
- **Filebeat tự harvest log của chính nó** → vòng lặp tự log, dòng metrics
  khổng lồ của nó bị parse lỗi liên tục, 10.000+ document rác trong 1 ngày.
  Đã loại trừ container `*filebeat*` khỏi điều kiện autodiscover.
- **Backend không tự rebuild khi submodule bump** dù GitOps đang chạy — nghi
  do chạy `git reset --hard` thủ công xen giữa lúc debug làm gitops bỏ lỡ thời
  điểm so sánh SHA. Luôn `docker compose build backend` tay sau khi biết chắc
  code backend đổi, đừng chỉ tin gitops khi đang can thiệp thủ công song song.

## Giới hạn đã biết (ponytail)

- ILM chỉ có delete sau 30 ngày (không rollover/warm tiers) — đủ cho 1 index/ngày.
- Logstash không filter/transform gì (Filebeat đã parse JSON sẵn) — chỉ đóng
  vai trò trung chuyển đúng chuẩn ELK. Nếu sau này cần enrich/filter dữ liệu
  (geoip theo `ip`, drop field nhạy cảm...), đây là chỗ thêm, không phải sửa
  Filebeat hay Django.
- KHÔNG có TLS giữa các container/VM (chỉ basic auth): log đi plaintext qua LAN
  trên cổng 5044/9200. Chấp nhận trong LAN nội bộ; nếu cần: Logstash `ssl_enabled`
  + `ssl_certificate/key` ở input beats, Filebeat `output.logstash.ssl.certificate_authorities`.
- pgpool/pg-witness KHÔNG có Filebeat riêng (chạy trên VM1, đã được Filebeat
  chung của VM1 thu qua Docker autodiscover) — chỉ pg-0/pg-1 (VM2/VM3) cần
  Filebeat riêng vì khác máy vật lý.
- Không cấu hình `log_connections`/`log_disconnections` trên Postgres: health
  check của pgpool chạy mỗi 10s/node, bật sẽ tạo log liên tục không cần thiết.
  Lỗi auth (`FATAL: password authentication failed`) vẫn được log mặc định vì
  severity FATAL luôn vượt ngưỡng `log_min_messages=warning`.
