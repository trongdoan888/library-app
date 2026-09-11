# HA DB tách 3 máy — hướng dẫn triển khai

Chuyển cụm Postgres HA từ "tất cả trên VM1" sang 3 máy:

| VM | IP | User | Thư mục repo | Chạy | File compose |
|----|----|------|------|------|--------------|
| VM1 | `192.168.111.136` | `trong` | `/home/trong/library-app` | backend, frontend, **pgpool**, **pg-witness**, pg-backup, pgadmin | `docker-compose.yml` |
| VM2 | `192.168.111.140` | `pg0` | `/home/pg0/library-app` | **pg-0** (Postgres node) | `docker-compose.pg0.yml` |
| VM3 | `192.168.111.142` | `pg1` | `/home/pg1/library-app` | **pg-1** (Postgres node) | `docker-compose.pg1.yml` |

Các node nối nhau qua **IP tĩnh + cổng 5432 publish trên mỗi host** (không dùng mạng
compose vì khác máy). Cụ thể trên VM1: `pg-witness` chiếm cổng 5432, `pgpool` publish
ra `5433` (backend vẫn nối `pgpool:5432` qua mạng compose nội bộ, không đổi).

> Trước khi bắt đầu: **backup DB hiện tại** (Phase 3). Cụm mới khởi tạo rỗng,
> phải nạp dữ liệu cũ vào.

---

## Phase 0 — Điều kiện trên cả VM2 và VM3

Làm **giống hệt nhau** trên VM2 và VM3.

### 0.1 IP tĩnh + phân giải tên

```bash
ip -4 addr show                     # xác nhận VM2 = .140, VM3 = .142, /24, cùng ens33
ping -c1 192.168.111.136            # thấy VM1
```
Đặt IP tĩnh trong netplan nếu đang là DHCP (`/etc/netplan/*.yaml` → `dhcp4: no` + `addresses`).

### 0.2 Đồng bộ giờ (repmgr rất nhạy với lệch giờ)

```bash
sudo apt update && sudo apt install -y chrony
sudo systemctl enable --now chrony
timedatectl                        # System clock synchronized: yes
```

### 0.3 Docker + compose plugin

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER" && newgrp docker
docker compose version             # v2.x
```

### 0.4 Firewall — mở 5432 trong LAN

```bash
sudo ufw allow ssh
sudo ufw allow from 192.168.111.0/24 to any port 5432 proto tcp
sudo ufw --force enable
sudo ufw status
```

### 0.5 Lấy code + `.env`

Trên **VM2** (user `pg0`, home `/home/pg0`):
```bash
git clone https://github.com/trongdoan888/library-app ~/library-app
```
Trên **VM3** (user `pg1`, home `/home/pg1`):
```bash
git clone https://github.com/trongdoan888/library-app ~/library-app
```

`.env` không nằm trong Git (`.gitignore`) — phải copy tay từ VM1, **sau khi** đã thêm
3 dòng `VM*_IP` vào `.env` của VM1 (xem đầu bài). Chạy từ VM1 hoặc từ Windows:

```bash
# từ VM1
scp ~/library-app/.env pg0@192.168.111.140:~/library-app/.env
scp ~/library-app/.env pg1@192.168.111.142:~/library-app/.env
```
```powershell
# hoặc từ Windows, nếu .env trên VM1 đã cập nhật và bạn có key/pass SSH VM1
scp trong@192.168.111.136:~/library-app/.env pg0@192.168.111.140:~/library-app/.env
scp trong@192.168.111.136:~/library-app/.env pg1@192.168.111.142:~/library-app/.env
```

---

## Phase 1 — Lấy config mới lên cả 3 VM

Các file `docker-compose.pg0.yml`, `docker-compose.pg1.yml`, `docker-compose.yml`
(bản VM1 mới), `deploy/gitops/reconcile.sh` (hỗ trợ `COMPOSE_FILE`) đã nằm trong repo.

```bash
# VM2 (pg0) & VM3 (pg1) — pull thoải mái, chưa có gì chạy
cd ~/library-app
git fetch origin main && git reset --hard origin/main
```

```bash
# VM1 — hạ stack CŨ bằng file CŨ TRƯỚC, rồi mới pull (xem Phase 4.1), nếu không
# `docker compose down` sau khi pull sẽ không biết pg-0/pg-1 để gỡ.
cd /home/trong/library-app
sudo systemctl stop gitops-agent.timer
docker exec library_pg_backup /usr/local/bin/backup-loop.sh once   # Phase 3 làm luôn ở đây
docker compose down
git fetch origin main && git reset --hard origin/main
```

Kiểm tra biến IP đã đọc được:
```bash
docker compose -f docker-compose.pg0.yml config | grep -E 'REPMGR_(NODE_NETWORK_NAME|PARTNER_NODES|PRIMARY_HOST)'
```

---

## Phase 2 — Kết nối mạng giữa các VM (kiểm tra trước khi dựng)

```bash
# từ VM1
nc -zv 192.168.111.140 5432 || echo "chưa lên - bình thường, pg-0 chưa chạy"
nc -zv 192.168.111.142 5432 || echo "chưa lên"
```
Chỉ cần chắc `nc` tới được cổng khi container chạy (Phase 4). Nếu `nc` báo *No route to host*
→ firewall/subnet sai, sửa Phase 0.4.

---

## Phase 3 — Backup dữ liệu hiện tại (trên VM1, cụm CŨ vẫn đang chạy)

```bash
cd /home/trong/library-app
# ép 1 bản dump ngay
docker exec library_pg_backup /usr/local/bin/backup-loop.sh once
docker exec library_pg_backup sh -c 'ls -t /backups/*.dump | head -1'
# copy bản .dump đó ra ngoài repo cho chắc
NEWEST=$(docker exec library_pg_backup sh -c 'ls -t /backups/*.dump | head -1')
docker exec library_pg_backup cat "$NEWEST" > ~/library-before-ha3.dump
ls -lh ~/library-before-ha3.dump
```

Giữ file `~/library-before-ha3.dump` — Phase 5 sẽ nạp lại.

---

## Phase 4 — Dựng cụm mới, đúng thứ tự

### 4.1 Dọn nốt container cũ trên VM1 (đã `down` ở Phase 1)

```bash
docker rm -f library_pg0 library_pg1 2>/dev/null || true
docker ps -a | grep library_   # chỉ còn (hoặc không còn) gì tuỳ Phase 1
```

### 4.2 VM2 (`pg0@192.168.111.140`) — pg-0 (primary)

```bash
cd ~/library-app
docker compose -f docker-compose.pg0.yml up -d
docker logs -f library_pg0
#   chờ: "database system is ready to accept connections"
#        "  [NOTICE] ... registered ... as primary"
```

### 4.3 VM3 (`pg1@192.168.111.142`) — pg-1 (standby, tự clone từ pg-0)

```bash
cd ~/library-app
docker compose -f docker-compose.pg1.yml up -d
docker logs -f library_pg1
#   chờ: "starting backup" / "pg_basebackup" -> "started streaming"
#        "  [NOTICE] ... registered ... as standby"
```

### 4.4 VM1 — witness + pgpool + app

```bash
cd /home/trong/library-app
docker compose up -d
docker logs -f library_pg_witness
#   chờ witness đăng ký. Xem "Phase 6" nếu image không nhận REPMGR_NODE_TYPE=witness.
```

### 4.5 Xác nhận cụm

Trên VM2 (hoặc bất kỳ node nào):
```bash
docker exec library_pg0 sh -c '
  export $(tr "\0" "\n" </proc/1/environ | grep -E "^(NSS_WRAPPER_PASSWD|NSS_WRAPPER_GROUP|LD_PRELOAD)=")
  repmgr -f /opt/bitnami/repmgr/conf/repmgr.conf cluster show'
```
Kỳ vọng:
```
 ID | Name       | Role    | Status    | Upstream | ...
 1  | pg-0       | primary | * running |          |
 2  | pg-1       | standby |   running | pg-0     |
 3  | pg-witness | witness | * running | pg-0     |
```

Trên VM1:
```bash
A=$(grep -E '^POSTGRES_ADMIN_PASSWORD=' .env | head -1 | cut -d= -f2- | tr -d '\r\n')
docker exec -e PGPASSWORD="$A" library_pgpool psql -h127.0.0.1 -Upostgres -c "show pool_nodes"
```
Kỳ vọng: 2 dòng, `0 pg-0 ... up primary`, `1 pg-1 ... up standby streaming`.

---

## Phase 5 — Nạp lại dữ liệu cũ

Nạp vào **primary** (pg-0 ở VM2). Streaming replication sẽ tự đẩy sang pg-1.

```bash
# từ VM1, đẩy file dump sang VM2:
scp ~/library-before-ha3.dump pg0@192.168.111.140:~/

# trên VM2:
cd ~/library-app
A=$(grep -E '^POSTGRES_ADMIN_PASSWORD=' .env | head -1 | cut -d= -f2- | tr -d '\r\n')
DB=$(grep -E '^POSTGRES_DB=' .env | head -1 | cut -d= -f2- | tr -d '\r\n')

cat ~/library-before-ha3.dump | docker exec -i -e PGPASSWORD="$A" library_pg0 \
  pg_restore -U postgres -d "$DB" --clean --if-exists --no-owner --no-privileges

# kiểm tra
docker exec -e PGPASSWORD="$A" library_pg0 psql -U postgres -d "$DB" -c "\dt"
```

Xác nhận pg-1 (VM3) đã nhận:
```bash
# trên VM3
A=$(grep -E '^POSTGRES_ADMIN_PASSWORD=' .env | head -1 | cut -d= -f2- | tr -d '\r\n')
DB=$(grep -E '^POSTGRES_DB=' .env | head -1 | cut -d= -f2- | tr -d '\r\n')
docker exec -e PGPASSWORD="$A" library_pg1 psql -U postgres -d "$DB" -c "\dt"
```

Rồi bật lại app trên VM1 (đã chạy ở 4.4, nhưng migrate lúc đó chạy trên DB rỗng —
restart để backend nối lại sạch):
```bash
# VM1
docker compose restart backend
curl -s -o /dev/null -w "backend=%{http_code}\n" -X POST http://localhost:8000/api/token/ \
  -H 'content-type: application/json' -d '{"username":"x","password":"x"}'   # 401 = OK
```

---

## Phase 6 — Witness (nếu image không nhận `REPMGR_NODE_TYPE=witness`)

Một số bản `bitnamilegacy/postgresql-repmgr` không có sẵn chế độ witness. Nếu
`library_pg_witness` khởi động lỗi hoặc `cluster show` không thấy dòng witness:

1. Bỏ `REPMGR_NODE_TYPE: witness` khỏi service `pg-witness` trong `docker-compose.yml`
   → nó chạy như 1 node repmgr thường (vẫn cho quorum, chỉ tốn thêm ít RAM).
   **HOẶC**
2. Đăng ký witness thủ công 1 lần:
   ```bash
   # VM1, sau khi container pg-witness chạy như node thường
   docker exec library_pg_witness sh -c '
     export $(tr "\0" "\n" </proc/1/environ | grep -E "^(NSS_WRAPPER_PASSWD|NSS_WRAPPER_GROUP|LD_PRELOAD)=")
     repmgr -f /opt/bitnami/repmgr/conf/repmgr.conf witness register -h 192.168.111.140 -U repmgr -d repmgr --force'
   ```

Không bắt buộc có witness để cụm chạy — nhưng thiếu nó, khi VM2↔VM3 mất mạng
có thể split-brain (cả hai cùng nhận primary), phải gỡ tay khi nối lại.

---

## Phase 7 — GitOps: 1 agent mỗi VM

Trên **VM2** và **VM3**, cài `gitops-agent` như VM1 nhưng đổi `User`, đường dẫn,
và trỏ đúng `COMPOSE_FILE`. Unit gốc trong repo hardcode `User=trong` +
`/home/trong/library-app` (đúng cho VM1) — VM2/VM3 phải sửa lại 2 dòng đó.

**VM2 (`pg0`)**
```bash
cd ~/library-app
sed -e 's#User=trong#User=pg0#' \
    -e 's#/home/trong/library-app#/home/pg0/library-app#g' \
    deploy/gitops/gitops-agent.service | sudo tee /etc/systemd/system/gitops-agent.service >/dev/null
sudo cp deploy/gitops/gitops-agent.timer /etc/systemd/system/

sudo mkdir -p /etc/systemd/system/gitops-agent.service.d
sudo tee /etc/systemd/system/gitops-agent.service.d/override.conf >/dev/null <<'EOF'
[Service]
Environment=COMPOSE_FILE=docker-compose.pg0.yml
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now gitops-agent.timer
journalctl -u gitops-agent.service -f   # 1 tick: "reconcile complete (file=docker-compose.pg0.yml changed=0)"
```

**VM3 (`pg1`)** — giống hệt, đổi `pg0`→`pg1` và `.pg0.yml`→`.pg1.yml`:
```bash
cd ~/library-app
sed -e 's#User=trong#User=pg1#' \
    -e 's#/home/trong/library-app#/home/pg1/library-app#g' \
    deploy/gitops/gitops-agent.service | sudo tee /etc/systemd/system/gitops-agent.service >/dev/null
sudo cp deploy/gitops/gitops-agent.timer /etc/systemd/system/
sudo mkdir -p /etc/systemd/system/gitops-agent.service.d
sudo tee /etc/systemd/system/gitops-agent.service.d/override.conf >/dev/null <<'EOF'
[Service]
Environment=COMPOSE_FILE=docker-compose.pg1.yml
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now gitops-agent.timer
journalctl -u gitops-agent.service -f
```

Trên **VM1** bật lại timer đã stop ở 4.1:
```bash
sudo systemctl start gitops-agent.timer
```

Từ giờ: push repo `library-app` → cả 3 VM tự `git reset --hard` + `docker compose -f <file của nó> up -d`.
Sửa cấu hình pg-0/pg-1 (image, env) = sửa `docker-compose.pg0.yml/.pg1.yml` rồi push.

---

## Phase 8 — Test HA cross-VM

Script `~/ha` cũ `docker exec` thẳng vào pg-0/pg-1 (giờ ở máy khác) — phần "giết
primary" phải đổi sang SSH:

```bash
# VM1 — theo dõi
A=$(grep -E '^POSTGRES_ADMIN_PASSWORD=' .env | head -1 | cut -d= -f2- | tr -d '\r\n')
watch -n3 "docker exec -e PGPASSWORD='$A' library_pgpool psql -h127.0.0.1 -Upostgres -c 'show pool_nodes'"

# giết primary (đang ở VM2, user pg0)
ssh pg0@192.168.111.140 'docker stop library_pg0'
#   -> witness + pg-1 bỏ phiếu -> pg-1 promote -> pgpool đổi tuyến sang .142
#   backend không đổi config, chỉ khựng vài giây

# hồi phục
ssh pg0@192.168.111.140 'docker start library_pg0'
#   -> repmgr tự rejoin pg-0 thành standby, pgpool auto_failback tự attach

# test chiều ngược lại: giết primary khi nó đã chuyển sang VM3
ssh pg1@192.168.111.142 'docker stop library_pg1'
ssh pg1@192.168.111.142 'docker start library_pg1'
```

---

## Sự cố thường gặp khi triển khai (đã gặp thật, xử lý như sau)

1. **`ufw` chặn Docker NAT-forward — bắt buộc sửa trên CẢ 3 VM, không chỉ 2 VM DB.**
   Triệu chứng: `pgpool`/`repmgrd` log `getsockopt() failed` / `Operation now in progress`
   / `timeout expired` khi 1 node cố nối tới IP của node khác (kể cả `pgpool` ở VM1 nối
   ra `${VM2_IP}`/`${VM3_IP}`), dù `nc` từ **host** (ngoài container) tới cùng địa chỉ
   lại thành công — vì `nc` ở host không đi qua chain `FORWARD` mà traffic từ container
   Docker phải đi qua. Sửa trên **từng VM**:
   ```bash
   sudo sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
   sudo systemctl restart ufw
   sudo systemctl restart docker   # bắt buộc — `restart ufw` một mình có thể làm
                                    # lệch thứ tự rule DOCKER/DOCKER-USER, phải restart
                                    # daemon để nó tự chèn lại đúng chỗ
   ```

2. **`network_mode: host` cho `pg-0`/`pg-1`/`pg-witness`.**
   Mỗi node repmgr tự kết nối tới **chính IP của nó** (`REPMGR_NODE_NETWORK_NAME`) để
   `repmgrd` tự giám sát — qua publish port bình thường đây là NAT-hairpin (container
   tự gọi ra ngoài rồi vòng lại chính mình) mà môi trường ảo hoá này không xử lý được,
   dẫn tới container crash-loop liên tục dù node KHÁC nối vào vẫn bình thường. 3 file
   compose đã đặt `network_mode: host` sẵn cho 3 service này — không cần `ports:`.

3. **`REPMGR_NODE_NAME` của witness phải khớp mẫu `<chữ>-<số>`.**
   `pg-witness` bị từ chối (`does not follow the required format`), phải đặt kiểu
   `witness-3`. Đã sửa trong `docker-compose.yml`.

4. **Sau nhiều lần container crash-loop, volume dữ liệu có thể dở dang.**
   Nếu thấy lỗi kiểu `repmgr extension not found` dù Postgres start bình thường —
   volume đã trải qua init dang dở từ các lần crash trước. Xoá volume, khởi tạo lại:
   ```bash
   docker compose -f docker-compose.pgX.yml down
   docker volume rm library-app_pg_X_data
   docker compose -f docker-compose.pgX.yml up -d
   ```

5. **Đổi `network_mode`/service definition thì phải `down` trước `up`**, `docker compose up -d`
   đơn thuần không luôn recreate đúng khi kiểu network thay đổi.

6. **`pgpool` có lúc kẹt `FATAL: all backend nodes are down` sau khi primary chết**, dù
   node còn lại đã lên primary và network vẫn thông (`nc` tới nó OK) — không tự thoát ra
   được như trong test 1-VM trước đó (SPOF về logic, không chỉ hạ tầng). Sửa bằng
   `docker compose restart pgpool` trên VM1; nếu vẫn kẹt, `sudo systemctl restart docker`
   trên VM1. Đây là bằng chứng thật cho việc pgpool 1 instance là điểm yếu — muốn hết
   hẳn phải chạy 2 pgpool + watchdog/VIP.

---

## Rollback về "tất cả trên VM1"

```bash
# VM1
git revert <commit tách HA>       # hoặc checkout docker-compose.yml bản cũ
docker compose -f docker-compose.yml down
docker compose up -d              # bản cũ có pg-0/pg-1 nội bộ
cat ~/library-before-ha3.dump | docker exec -i -e PGPASSWORD="$A" library_pg0 \
  pg_restore -U postgres -d library --clean --if-exists --no-owner
# VM2/VM3: docker compose -f docker-compose.pgX.yml down -v
```
