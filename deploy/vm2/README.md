# Phần 2 — Tách pg-1 sang VM2 (HA database 2 máy)

Kết quả: `pg-0` chạy trên **VM1** (primary), `pg-1` chạy trên **VM2** (standby, tự
promote khi VM1 chết). `pgpool` + backend + frontend + pg-backup vẫn ở VM1.

Cấu hình đã chốt:

| | VM1 | VM2 |
|---|---|---|
| IP (NAT, card `ens33`) | `192.168.111.136` (DHCP hiện tại) | `192.168.111.137` (tĩnh, đặt ở bước 2) |
| Gateway | `192.168.111.2` | `192.168.111.2` |
| compose | `docker-compose.yml` | `compose.vm2.yml` |

> ⚠️ VM1 đang để DHCP. Nếu VMware cấp IP khác cho VM1 sau reboot, cụm sẽ hỏng
> (repmgr ghi cứng IP). Nên vào **Virtual Network Editor → VMnet8 → DHCP Settings**
> trên Windows, hoặc sửa `C:\ProgramData\VMware\vmnetdhcp.conf`, thêm reservation:
> ```
> host vm1 { hardware ethernet 00:0c:29:ad:4a:cb; fixed-address 192.168.111.136; }
> ```
> rồi restart service **VMware DHCP Service**.

---

## Bước 1 — Tạo VM2 trong VMware

- New VM → cùng ISO Ubuntu Server như VM1 → 2 vCPU / 3–4 GB RAM / 20 GB disk.
- Network Adapter: **NAT** (giống VM1, cùng VMnet8).
- Sau khi cài xong, đăng nhập VM2:

```bash
# Docker + compose plugin
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER"        # logout/login lại

# user + thư mục giống VM1 để đường dẫn đồng nhất
sudo useradd -m -s /bin/bash trong && sudo usermod -aG docker trong
sudo mkdir -p /home/trong && sudo chown trong:trong /home/trong

docker compose version                 # kiểm tra
```

## Bước 2 — IP tĩnh cho VM2

```bash
ip -4 -o addr show scope global | grep -Ev 'docker|br-|veth'   # xác nhận card = ens33
```

```bash
sudo tee /etc/netplan/01-static.yaml >/dev/null <<'EOF'
network:
  version: 2
  ethernets:
    ens33:
      dhcp4: false
      addresses: [192.168.111.137/24]
      routes:
        - to: default
          via: 192.168.111.2
      nameservers:
        addresses: [192.168.111.2, 8.8.8.8]
EOF
sudo chmod 600 /etc/netplan/01-static.yaml

# nếu có file netplan cũ để dhcp4: true thì đổi thành false hoặc xoá nó
sudo netplan apply
ip -4 addr show ens33          # phải thấy 192.168.111.137
```

Kiểm tra 2 chiều (chạy 2 lệnh, mỗi lệnh ở 1 VM):

```bash
# trên VM2:
ping -c2 192.168.111.136 && ping -c2 8.8.8.8
# trên VM1:
ping -c2 192.168.111.137
```

Firewall: mặc định Ubuntu Server không bật ufw. Kiểm tra `sudo ufw status`.
Nếu **active**, mở cổng Postgres giữa 2 VM:

```bash
# VM1
sudo ufw allow from 192.168.111.137 to any port 5432 proto tcp
# VM2
sudo ufw allow from 192.168.111.136 to any port 5432 proto tcp
```

## Bước 3 — Dừng gitops agent trên VM1

Không cho agent tự `docker compose up` chen ngang lúc đang dựng lại cụm:

```bash
sudo systemctl stop gitops-agent.timer
```

## Bước 4 — Chụp 1 bản backup mới nhất (trên VM1)

```bash
docker exec library_pg_backup /usr/local/bin/backup-loop.sh once
docker exec library_pg_backup sh -c 'ls -t /backups/*.dump | head -1'   # nhớ tên file này
```

## Bước 5 — Lấy code + .env mới về 2 VM

Các file `docker-compose.yml`, `compose.vm2.yml`, `.env.example` mới đã commit lên
`origin/main` (bạn push từ máy Windows trước khi làm bước này).

**VM1:**
```bash
cd /home/trong/library-app
git fetch origin main && git reset --hard origin/main

# thêm 2 dòng IP vào .env (file .env KHÔNG nằm trong git)
grep -q '^VM1_IP=' .env || printf '\nVM1_IP=192.168.111.136\nVM2_IP=192.168.111.137\n' >> .env
docker compose config >/dev/null && echo "compose OK"
```

**VM2:**
```bash
sudo -u trong git clone --recurse-submodules \
  https://github.com/trongdoan888/library-app /home/trong/library-app
```
> Repo library-app dùng submodule qua HTTPS; nếu private thì cấu hình credhelper /
> deploy key trước. VM2 **không build** backend/frontend nên submodule không bắt buộc
> phải kéo được — kệ nếu nó cảnh báo.

Copy `.env` từ VM1 sang VM2 (giống hệt):
```bash
# chạy trên VM1 (VM2 phải có sshd — Ubuntu Server mặc định có)
scp /home/trong/library-app/.env trong@192.168.111.137:/home/trong/library-app/.env
```

## Bước 6 — Dựng lại cụm sạch

**VM1** — xoá cụm cũ + volume replication cũ, dựng primary mới:
```bash
cd /home/trong/library-app
docker compose down
docker volume ls | grep pg_          # xem tên thật, thường là library-app_pg_0_data / _pg_1_data
docker volume rm library-app_pg_0_data library-app_pg_1_data

docker compose up -d pg-0
docker compose logs -f pg-0
# chờ tới khi thấy: "database system is ready to accept connections"
# và "starting monitoring of node \"pg-0\"" (repmgr)
```

**VM2** — dựng standby, nó tự clone từ 192.168.111.136:
```bash
cd /home/trong/library-app
docker compose -f compose.vm2.yml up -d
docker compose -f compose.vm2.yml logs -f pg-1
# kỳ vọng: "starting backup ... from primary", rồi
# "started streaming WAL from primary at ..." / "entering standby mode"
```

## Bước 7 — Nạp lại dữ liệu vào primary (trên VM1)

```bash
set -a; source /home/trong/library-app/.env; set +a
docker exec library_pg_backup sh -c 'ls -t /backups/*.dump | head -1'   # tên file dump
DUMP=<tên_file_dump_ở_trên>          # ví dụ library-2026-09-08_131900.dump

docker exec library_pg_backup cat "/backups/$DUMP" \
  | docker exec -i -e PGPASSWORD="$POSTGRES_ADMIN_PASSWORD" library_pg0 \
      pg_restore -U postgres -d "$POSTGRES_DB" --clean --if-exists --no-owner
```

Dữ liệu ghi vào pg-0 sẽ tự replicate sang pg-1 ở VM2.

## Bước 8 — Bật phần còn lại (trên VM1)

```bash
docker compose up -d          # pgpool, pgadmin, pg-backup, backend, frontend
docker compose ps
```

## Bước 9 — Xác minh HA

```bash
set -a; source /home/trong/library-app/.env; set +a

# 1) repmgr thấy 2 node
docker exec library_pg0 repmgr -f /opt/bitnami/repmgr/conf/repmgr.conf cluster show
#  ID | Name | Role    | Status    | ...
#   1 | pg-0 | primary | * running
#   2 | pg-1 | standby |   running

# 2) primary thấy standby đang stream, client_addr = IP VM2
docker exec -e PGPASSWORD="$POSTGRES_ADMIN_PASSWORD" library_pg0 \
  psql -U postgres -c "SELECT client_addr, state, sync_state FROM pg_stat_replication;"
#  client_addr = 192.168.111.137 | state = streaming

# 3) pgpool thấy 2 node "up"
docker exec library_pgpool psql -h 127.0.0.1 -U postgres -c "SHOW pool_nodes;"
#  node 0 pg-0 ... up ... primary   | node 1 192.168.111.137 ... up ... standby
```

App test: mở frontend, tạo/sửa 1 bản ghi → OK là đường ghi qua pgpool→primary chạy.

## Bước 10 — gitops agent trên VM2

```bash
sudo cp /home/trong/library-app/deploy/vm2/reconcile-vm2.sh /usr/local/bin/reconcile-vm2.sh
sudo chmod +x /usr/local/bin/reconcile-vm2.sh

sudo cp /home/trong/library-app/deploy/gitops/gitops-agent.service /etc/systemd/system/
sudo cp /home/trong/library-app/deploy/gitops/gitops-agent.timer   /etc/systemd/system/
sudo sed -i 's#ExecStart=.*#ExecStart=/usr/local/bin/reconcile-vm2.sh#' \
  /etc/systemd/system/gitops-agent.service

sudo systemctl daemon-reload
sudo systemctl enable --now gitops-agent.timer
systemctl list-timers gitops-agent.timer
```

## Bước 11 — Bật lại gitops agent trên VM1

```bash
sudo systemctl start gitops-agent.timer
systemctl list-timers gitops-agent.timer
```

## Bước 12 — Diễn tập failover (BẮT BUỘC làm 1 lần)

```bash
set -a; source /home/trong/library-app/.env; set +a

# 1. Hạ primary (trên VM1)
docker stop library_pg0

# 2. Xem pg-1 tự lên primary (trên VM2), đợi ~30–60s
docker exec library_pg1 repmgr -f /opt/bitnami/repmgr/conf/repmgr.conf cluster show
#   pg-1 | primary | * running   ;  pg-0 | primary | - failed

# 3. App vẫn ghi được? pgpool đã trỏ sang node 1
docker exec library_pgpool psql -h 127.0.0.1 -U postgres -c "SHOW pool_nodes;"

# 4. Đưa pg-0 quay lại làm standby (trên VM1)
docker start library_pg0
docker exec library_pg0 repmgr -f /opt/bitnami/repmgr/conf/repmgr.conf node rejoin \
  -d "host=192.168.111.137 user=repmgr dbname=repmgr password=$REPMGR_PASSWORD" \
  --force-rewind --verbose
docker exec library_pg1 repmgr -f /opt/bitnami/repmgr/conf/repmgr.conf cluster show
#   pg-1 primary, pg-0 standby running
```

Nếu bước 4 báo phân kỳ nặng không rejoin được:
```bash
docker stop library_pg0
docker volume rm library-app_pg_0_data
docker compose up -d pg-0        # clone lại sạch từ primary mới (pg-1)
```

> Lưu ý sau failover: primary hiện là pg-1 (VM2). `pg-backup` sẽ tự nhận ra và dump
> từ pg-1 (script ưu tiên node không ở chế độ recovery). Không cần chỉnh gì.

---

## Sự cố thường gặp

| Triệu chứng | Nguyên nhân / cách xử lý |
|---|---|
| pg-1 log: `could not connect to server 192.168.111.136:5432` | VM2 chưa thông tới VM1 (sai IP tĩnh / ufw). Test `nc -vz 192.168.111.136 5432` từ VM2. |
| pg-1 log: `FATAL: password authentication failed for user "repmgr"` | `.env` 2 máy khác nhau (`REPMGR_PASSWORD`). Copy lại `.env` từ VM1. |
| `cluster show` chỉ thấy pg-0 | pg-1 chưa register — xem `docker compose -f compose.vm2.yml logs pg-1`, thường do bước clone lỗi ở trên. |
| `pg_stat_replication` rỗng | standby chưa stream. Kiểm tra volume `pg_1_data` có bị dính dữ liệu cũ không → `docker compose -f compose.vm2.yml down && docker volume rm library-app_pg_1_data && up`. |
| pgpool `SHOW pool_nodes` node 1 `down` | pgpool trong container không tới được `192.168.111.137:5432`. Test từ VM1: `docker exec library_pgpool nc -vz 192.168.111.137 5432`. |
| VM1 đổi IP sau reboot | Sửa `VM1_IP` trong `.env` ở **cả 2 VM**, rồi làm lại từ Bước 6. Đặt DHCP reservation để khỏi gặp lại. |
