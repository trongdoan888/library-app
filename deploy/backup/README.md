# pg-backup — backup Postgres mỗi 6h ra máy thật

Container `library_pg_backup` chạy trên VM1. Mỗi 6 giờ (`BACKUP_INTERVAL=21600`)
nó chạy `pg_dump -Fc` trên node primary rồi ghi file
`library-YYYY-MM-DD_HHMMSS.dump` **thẳng ra thư mục trên máy thật Windows**:

```
C:\Users\doant\OneDrive\Documents\Desktop\pg-backups
```

Đường đi: container → volume CIFS `host_pg_backups` → SMB share `\\WIN_HOST_IP\pg-backups`
→ thư mục trên. Không cần cấu hình `/etc/fstab` trên VM.

Giữ lại `KEEP=28` bản mới nhất, bản cũ hơn tự xoá.

---

## 1. Chuẩn bị trên máy thật (Windows) — làm 1 lần

1. Tạo thư mục `C:\Users\doant\OneDrive\Documents\Desktop\pg-backups`.
   - Chuột phải → **Properties → OneDrive** (hoặc menu chuột phải) → **Always keep on this device**
     để OneDrive không "đẩy file lên mây" làm chậm ghi/khó restore.
2. Tạo local user riêng cho SMB (đừng dùng tài khoản Microsoft):
   Settings → Accounts → Other users → Add account → *I don't have this person's sign-in* →
   *Add a user without a Microsoft account* → user `pgbackup` + mật khẩu mạnh.
3. Chia sẻ thư mục: chuột phải thư mục `pg-backups` → **Properties → Sharing →
   Advanced Sharing** → tick *Share this folder* → **Share name: `pg-backups`** →
   **Permissions** → Add `pgbackup` → tick **Change** + **Read** → OK.
4. Firewall: Control Panel → Windows Defender Firewall → *Allow an app* →
   bật **File and Printer Sharing** cho profile **Private**.
5. Lấy IP máy Windows: PowerShell → `ipconfig` → ghi lại địa chỉ IPv4 của card mạng
   mà VM nhìn thấy (nếu VM để **Bridged** thì là IP LAN; nếu **NAT** thì thường là
   địa chỉ `...1` của adapter *VMware Network Adapter VMnet8*).

Kiểm tra nhanh từ VM1:

```bash
sudo apt install -y smbclient
smbclient -L //WIN_HOST_IP -U pgbackup      # phải thấy share "pg-backups"
```

## 2. Điền `.env`

Trong `library-app/.env` (trên VM1) thêm:

```
WIN_HOST_IP=<IP máy Windows>
SMB_USERNAME=pgbackup
SMB_PASSWORD=<mật khẩu user pgbackup>
```

> Mật khẩu SMB **không được chứa dấu phẩy `,`** (vướng cú pháp mount option). Các ký tự
> khác thì ổn.

VM1 cần sẵn module CIFS (đa số đã có; nếu thiếu): `sudo apt install -y cifs-utils`.

## 3. Chạy

```bash
cd /home/trong/library-app
docker compose build pg-backup
docker compose up -d pg-backup
docker logs -f library_pg_backup
```

Log kỳ vọng:

```
... [pg-backup] khởi động | interval=21600s keep=28 nodes='pg-0:5432 pg-1:5432' ...
... [pg-backup] dump từ pg-0:5432 -> library-2026-09-07_143000.dump
... [pg-backup] OK library-2026-09-07_143000.dump (1.2M)
```

Kiểm tra trên Windows: mở `C:\Users\doant\OneDrive\Documents\Desktop\pg-backups`
thấy file `.dump` vừa tạo.

### Ép chạy ngay 1 lần (không đợi 6h)

```bash
docker exec library_pg_backup /usr/local/bin/backup-loop.sh once
```

## 4. Khôi phục từ 1 file .dump

File nằm cả trên Windows lẫn trong container tại `/backups`. Restore vào primary:

```bash
set -a; source /home/trong/library-app/.env; set +a

# xem các bản có sẵn
docker exec library_pg_backup sh -c 'ls -t /backups/*.dump'

# nạp lại (ví dụ file library-2026-09-07_143000.dump)
docker exec library_pg_backup cat /backups/library-2026-09-07_143000.dump \
  | docker exec -i -e PGPASSWORD="$POSTGRES_ADMIN_PASSWORD" library_pg0 \
      pg_restore -U postgres -d "$POSTGRES_DB" --clean --if-exists --no-owner
```

Muốn thử an toàn thì restore vào DB tạm:

```bash
docker exec -e PGPASSWORD="$POSTGRES_ADMIN_PASSWORD" library_pg0 psql -U postgres -c "CREATE DATABASE restore_test;"
docker exec library_pg_backup cat /backups/<file>.dump \
  | docker exec -i -e PGPASSWORD="$POSTGRES_ADMIN_PASSWORD" library_pg0 pg_restore -U postgres -d restore_test --no-owner
docker exec -e PGPASSWORD="$POSTGRES_ADMIN_PASSWORD" library_pg0 psql -U postgres -d restore_test -c "\dt"
docker exec -e PGPASSWORD="$POSTGRES_ADMIN_PASSWORD" library_pg0 psql -U postgres -c "DROP DATABASE restore_test;"
```

## 5. Chỉnh tần suất / số bản giữ

Sửa `environment` của service `pg-backup` trong `docker-compose.yml`:

| Biến              | Mặc định | Ý nghĩa                                  |
|-------------------|----------|-----------------------------------------|
| `BACKUP_INTERVAL` | `21600`  | Giây giữa 2 lần dump (21600 = 6h)        |
| `KEEP`            | `28`     | Số file `.dump` mới nhất giữ lại         |
| `PG_NODES`        | `pg-0:5432 pg-1:5432` | Danh sách node thử dump (ưu tiên primary) |

Sau khi tách `pg-1` sang VM2, đổi `PG_NODES` thành `"pg-0:5432 <VM2_IP>:5432"`.

## Ghi chú vận hành

- Sửa `backup-loop.sh` xong phải build lại: `docker compose build pg-backup && docker compose up -d pg-backup`
  (gitops agent chỉ tự rebuild `backend`/`frontend`).
- `pg_dump` chạy trên primary; DB thư viện nhỏ nên ảnh hưởng không đáng kể. Nếu muốn
  đỡ tải primary, thêm node standby vào `PG_NODES` và bỏ node primary — script sẽ dump
  từ standby.
- Container này **độc lập** với backup `pg_dump + restic` ở Phần 1 (nếu có chạy song
  song thì cứ để, coi như 2 lớp).
