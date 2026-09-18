# Demo & kiểm tra GitOps

## Kiểm tra nhanh GitOps đang khoẻ (chạy trên VM1)

```bash
systemctl is-active gitops-agent.timer          # trạng thái timer: phải "active" (đang bật, sẽ tự tick mỗi 2 phút)
systemctl list-timers gitops-agent.timer        # xem lần agent chạy gần nhất + còn bao lâu tới lần chạy kế tiếp
systemctl status gitops-agent.service --no-pager -l   # lần chạy service gần nhất thành công hay lỗi, kèm vài dòng log
docker inspect --format='{{json .State.Health}}' library_pgpool   # đọc kết quả healthcheck pgpool - phải thấy "Status":"healthy"
docker compose -f /home/trong/library-app/docker-compose.yml ps   # liệt kê mọi container trong stack - phải "Up"/"running" hết
```

## Kiểm tra backup Postgres đang chạy đúng (VM1)

```bash
docker compose -f /home/trong/library-app/docker-compose.yml ps pg-backup   # container library_pg_backup phải "Up"
docker logs --tail 20 library_pg_backup                                    # xem log lần dump gần nhất: "OK <file>.dump (...)"
docker exec library_pg_backup sh -c 'ls -lt /backups/*.dump | head -5'      # 5 bản .dump mới nhất trong container (qua CIFS)
```

Trên Windows, mở thư mục `C:\Users\doant\OneDrive\Documents\Desktop\pg-backups`
để đối chiếu file `.dump` mới nhất khớp với log trên.

### Ép chạy backup ngay (không đợi chu kỳ 6h)

```bash
docker exec library_pg_backup /usr/local/bin/backup-loop.sh once   # chạy pg_dump 1 lần rồi thoát
docker logs --tail 5 library_pg_backup                             # xác nhận dòng "OK ...dump" mới xuất hiện
```

### Test restore an toàn (vào DB tạm, không đụng DB thật)

```bash
set -a; source /home/trong/library-app/.env; set +a

docker exec library_pg_backup sh -c 'ls -t /backups/*.dump' | head -1   # chọn file mới nhất để test

docker exec -e PGPASSWORD="$POSTGRES_ADMIN_PASSWORD" library_pg0 \
  psql -U postgres -c "CREATE DATABASE restore_test;"
docker exec library_pg_backup cat /backups/<file>.dump \
  | docker exec -i -e PGPASSWORD="$POSTGRES_ADMIN_PASSWORD" library_pg0 \
      pg_restore -U postgres -d restore_test --no-owner
docker exec -e PGPASSWORD="$POSTGRES_ADMIN_PASSWORD" library_pg0 \
  psql -U postgres -d restore_test -c "\dt"                          # phải thấy đủ bảng
docker exec -e PGPASSWORD="$POSTGRES_ADMIN_PASSWORD" library_pg0 \
  psql -U postgres -c "DROP DATABASE restore_test;"                  # dọn dẹp DB test
```

Chi tiết đầy đủ (cấu hình SMB, restore thật vào primary, đổi tần suất/số bản
giữ) xem [`deploy/backup/README.md`](backup/README.md).

## Demo full luồng GitOps (push → CI → agent tự deploy)

**Chuẩn bị:** SSH vào VM1, mở sẵn 1 cửa sổ theo dõi log real-time, để chạy
suốt buổi demo:
```bash
journalctl -u gitops-agent.service -f   # theo dõi log gitops-agent theo thời gian thực
```

### 1. Push thay đổi nhỏ (máy dev, trong `backend_library` hoặc `frontend_library`)

```bash
git add -A && git commit -m "demo: gitops" && git push origin main
# add -A: gom hết file đã sửa
# commit:  tạo 1 commit demo
# push:    đẩy lên GitHub main -> kích hoạt workflow CI (deploy.yml)
```

### 2. Xem trên GitHub

Tab **Actions** của repo vừa push: job `gitleaks` → `trivy-fs` →
`trivy-image` chạy song song (scan bảo mật/lỗ hổng — hiện đặt
`exit-code: 0` nên chỉ để xem, chưa chặn deploy thật), rồi job
`bump-library-app` chạy sau khi cả 3 pass — job này checkout repo
`library-app`, ghim submodule sang đúng SHA vừa push, tự tạo commit
`chore: bump ... to <sha>` và tự push (không phải bạn push tay) bằng
token `LIBRARY_APP_PUSH_TOKEN`. Qua tab **Commits** của repo
`library-app`, refresh, sẽ thấy commit đó do `github-actions[bot]` tạo —
đây là thay đổi duy nhất mà GitOps agent nhận biết được để rebuild.

### 3. Ép agent chạy ngay (VM1), không cần đợi tick tự nhiên (tối đa 2 phút)

```bash
sudo systemctl start gitops-agent.service             # kích thủ công 1 lần chạy reconcile.sh ngay, không đợi timer
journalctl -u gitops-agent.service -n 20 --no-pager   # xem 20 dòng log cuối của lần chạy vừa rồi
```

Kỳ vọng thấy tuần tự:
```
library-app main updated: <old> -> <new>              # repo cha đã đổi commit (do bước bump ở trên)
backend_library changed: <old-sha> -> <new-sha>, rebuilding   # submodule đổi SHA -> agent build lại image
reconcile complete (file=docker-compose.yml changed=1)         # hoàn tất, changed=1 = có rebuild thật
```

### 4. Xác nhận đã deploy đúng bản mới

```bash
docker compose -f docker-compose.yml ps backend   # cột STATUS: container backend phải vừa "Up" vài giây/phút trước (vừa recreate)
```

### 5. Demo rollback (máy dev)

```bash
git log --oneline -5                       # xem 5 commit gần nhất, tìm đúng commit "chore: bump backend_library to <sha>"
git revert <bump-commit-sha> --no-edit     # tạo 1 commit MỚI đảo ngược commit bump đó (không xoá lịch sử)
git push origin main                       # đẩy commit revert lên -> submodule pin quay lại SHA cũ
```

Trên VM1:
```bash
sudo systemctl start gitops-agent.service   # ép agent tick ngay
```
Log sẽ hiện đổi ngược `backend_library changed: <new-sha> -> <old-sha>`,
container `backend` tự build lại về đúng bản cũ. Nhấn mạnh: **rollback =
1 commit revert trên Git, không SSH deploy tay.**

### 6. Demo tự phục hồi drift (VM1)

```bash
docker stop library_backend                     # giả lập ai đó lỡ tay/cố ý tắt container ngoài ý muốn
sudo systemctl start gitops-agent.service       # ép tick - reconcile.sh luôn chạy "docker compose up -d --remove-orphans" ở cuối mỗi lần, kể cả khi Git không đổi gì
docker compose -f docker-compose.yml ps backend # xác nhận container tự "Up" trở lại
```
