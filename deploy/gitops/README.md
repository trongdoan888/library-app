# GitOps agent cho library-app

Thay cho việc CI (self-hosted runner) đẩy code thẳng vào VM, agent này chạy
**trên chính VM**, định kỳ tự `git fetch` + `docker compose build/up` —
Git luôn là nguồn sự thật, không ai/không job CI nào cần quyền ghi trực
tiếp vào máy chủ production nữa.

## Cài đặt (chạy trên VM, qua SSH — không chạy trên máy dev)

```bash
# 1. Đảm bảo repo đã ở đúng chỗ (đã có sẵn theo deploy.yml hiện tại)
cd /home/trong/library-app
git pull origin main   # để lấy các file trong deploy/gitops/ này

# 2. Cấp quyền chạy cho script
chmod +x deploy/gitops/reconcile.sh

# 3. Cài systemd units
sudo cp deploy/gitops/gitops-agent.service /etc/systemd/system/
sudo cp deploy/gitops/gitops-agent.timer /etc/systemd/system/
sudo systemctl daemon-reload

# 4. Bật timer (chạy lần đầu ngay + lặp lại mỗi 2 phút)
sudo systemctl enable --now gitops-agent.timer

# 5. Kiểm tra
systemctl list-timers gitops-agent.timer
sudo systemctl start gitops-agent.service   # chạy thử ngay 1 lần
journalctl -u gitops-agent.service -f       # xem log
```

Chỉnh `User=` trong `gitops-agent.service` nếu user chạy docker trên VM
không phải `trong`, và đảm bảo user đó nằm trong nhóm `docker` (để chạy
`docker compose` không cần sudo — giống cách self-hosted runner hiện tại
đang chạy).

## Sau khi agent đã chạy ổn định: gỡ bước "push deploy" khỏi CI

Trong `backend_library/.github/workflows/deploy.yml` và
`frontend_library/.github/workflows/deploy.yml`, job `deploy` (bước
`git reset --hard` + `docker compose build/up` trên self-hosted runner)
không còn cần thiết nữa — agent trên VM đã tự làm việc đó. Đề xuất xoá
hẳn job `deploy`, chỉ giữ lại `gitleaks` / `trivy-fs` / `trivy-image` làm
cổng kiểm tra chất lượng cho PR/push. Việc này đổi hành vi deploy thật nên
mình chưa tự sửa — nói khi nào bạn muốn áp dụng.

## Versioned & immutable — submodule ghim SHA, không đuổi theo `main`

`reconcile.sh` checkout `backend_library`/`frontend_library` đúng SHA đã
**ghim sẵn** trong cây git của `library-app` (không còn `--remote`). Con
trỏ đó chỉ di chuyển khi có 1 commit `chore: bump <submodule> to <sha>`
trên `library-app` main — commit này do CI của chính `backend_library`/
`frontend_library` tự tạo (job `bump-library-app` trong `deploy.yml`, chạy
sau khi `gitleaks`/`trivy` pass, dùng secret `LIBRARY_APP_PUSH_TOKEN`).

Kết quả: lịch sử Git của `library-app` phản ánh đúng 100% "commit nào đang
chạy tại thời điểm nào" — merge vào `backend_library`/`frontend_library`
main không tự deploy ngay, mà kích hoạt CI tạo commit bump, GitOps agent
mới thấy `library-app main updated` và rebuild.

## Kiểm thử & rollback

- Push 1 thay đổi nhỏ vào `backend_library` hoặc `frontend_library` main →
  đợi CI chạy xong (`gitleaks`/`trivy` + job `bump-library-app`) → đợi tối
  đa 2 phút để agent trên VM tick → xem `journalctl -u gitops-agent.service`
  để thấy nó tự rebuild.
- Rollback: `git revert` commit **`chore: bump ...`** trên nhánh `main` của
  **`library-app`** (không phải ở repo submodule nữa) — tick kế tiếp của
  agent sẽ tự đưa container về đúng SHA cũ. Không cần SSH vào VM để deploy
  tay.
- Drift tự phục hồi: nếu ai đó `docker stop backend` trên VM, tick kế tiếp
  (`docker compose up -d --remove-orphans` trong reconcile.sh) sẽ tự khởi
  động lại nó.

## Nâng cấp tuỳ chọn (không bắt buộc)

- **Event-driven thay vì polling 2 phút**: thêm GitHub webhook trỏ vào một
  listener nhỏ trên VM (vd. `adnanh/webhook`) chỉ để *trigger*
  `systemctl start gitops-agent.service` ngay khi có push — vẫn giữ đúng
  tinh thần pull (agent tự đọc Git, không nhận code push qua webhook).
- **Chặn deploy khi scan phát hiện vấn đề**: hiện `gitleaks`/`trivy` đặt
  `exit-code: 0` (không bao giờ fail job) nên job `bump-library-app` luôn
  chạy dù scan có cảnh báo. Muốn scan thật sự chặn deploy thì đổi thành
  `exit-code: 1` — khi đó `needs: [gitleaks, trivy-fs, trivy-image]` mới
  có ý nghĩa gate thật.
- **UI/dashboard**: nếu muốn xem trạng thái sync trực quan, cân nhắc
  [Komodo](https://komo.do) — tool self-hosted làm đúng việc GitOps cho
  Docker Compose, có UI thay vì chỉ đọc log qua `journalctl`.
