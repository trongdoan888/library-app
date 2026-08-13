# Library App

Ứng dụng quản lý thư viện gồm 3 phần:

- **backend_library** — Django + Django REST Framework (submodule git)
- **frontend_library** — Next.js (submodule git)
- **db** — PostgreSQL 16 (+ pgAdmin 4 để quản trị DB qua web)

Toàn bộ hệ thống được đóng gói bằng Docker và chạy chung qua [docker-compose.yml](docker-compose.yml).

---

## Phần 1: Hướng dẫn triển khai dự án

### 1. Yêu cầu môi trường

- [Docker](https://docs.docker.com/get-docker/) & Docker Compose plugin
- [Git](https://git-scm.com/) (có hỗ trợ submodule)

### 2. Clone dự án (kèm submodule)

Repo gốc chỉ chứa `docker-compose.yml` và tham chiếu tới 2 submodule `backend_library`, `frontend_library`. Khi clone cần lấy luôn submodule:

```bash
git clone --recurse-submodules <url-repo-library-app>
cd library-app
```

Nếu đã clone mà quên `--recurse-submodules`:

```bash
git submodule update --init --recursive
```

### 3. Cấu hình biến môi trường

Sao chép file mẫu `.env.example` thành `.env` ở thư mục gốc rồi chỉnh lại giá trị cho phù hợp:

```bash
cp .env.example .env
```

Nội dung cần khai báo trong `.env`:

| Biến | Mô tả |
| --- | --- |
| `POSTGRES_DB` | Tên database |
| `POSTGRES_USER` | User đăng nhập PostgreSQL |
| `POSTGRES_PASSWORD` | Mật khẩu PostgreSQL |
| `POSTGRES_PORT` | Cổng expose PostgreSQL (mặc định `5432`) |
| `PGADMIN_DEFAULT_EMAIL` | Email đăng nhập pgAdmin |
| `PGADMIN_DEFAULT_PASSWORD` | Mật khẩu đăng nhập pgAdmin |
| `DJANGO_SECRET_KEY` | Secret key của Django — **bắt buộc đổi** ở production |
| `DJANGO_DEBUG` | `True`/`False` — luôn để `False` ở production |
| `DJANGO_ALLOWED_HOSTS` | Danh sách host được phép, cách nhau dấu phẩy |
| `DJANGO_CORS_ALLOWED_ORIGINS` | Danh sách origin frontend được phép gọi API |
| `NEXT_PUBLIC_API_URL` | URL backend mà frontend gọi tới (được build cứng vào bundle Next.js, xem lưu ý bên dưới) |

> ⚠️ `NEXT_PUBLIC_API_URL` được Next.js nhúng vào bundle client **tại thời điểm build** (build ARG trong `frontend_library/Dockerfile`), không phải lúc chạy container. Nếu đổi giá trị này phải build lại image frontend (`docker compose build frontend`).

### 4. Build & chạy toàn bộ hệ thống

```bash
docker compose up -d --build
```

Lệnh này sẽ khởi tạo 4 service:

| Service | Container | Cổng |
| --- | --- | --- |
| `db` (PostgreSQL 16) | `library_db` | `5432` |
| `pgadmin` | `library_pgadmin` | `5050` |
| `backend` (Django) | `library_backend` | `8000` |
| `frontend` (Next.js) | `library_frontend` | `3000` |

`backend` chỉ khởi động sau khi `db` healthy; `frontend` khởi động sau `backend`. Khi container backend chạy, [entrypoint.sh](backend_library/entrypoint.sh) tự động chạy `python manage.py migrate` trước khi start server — không cần migrate thủ công cho lần deploy đầu.

### 5. Kiểm tra sau khi triển khai

- Frontend: http://localhost:3000
- Backend API: http://localhost:8000
- pgAdmin: http://localhost:5050 (đăng nhập bằng `PGADMIN_DEFAULT_EMAIL` / `PGADMIN_DEFAULT_PASSWORD`)

Xem log nếu có lỗi:

```bash
docker compose logs -f backend
docker compose logs -f frontend
```

### 6. Các lệnh vận hành thường dùng

```bash
# Dừng toàn bộ hệ thống (giữ lại volume dữ liệu)
docker compose down

# Rebuild và restart 1 service cụ thể (giống bước CI/CD làm ở phần 2)
docker compose build backend
docker compose up -d backend

# Dọn image thừa sau khi rebuild
docker image prune -f

# Chạy các lệnh Django quản trị (tạo superuser, ...)
docker compose exec backend python manage.py createsuperuser
```

### 7. Chạy riêng từng phần khi phát triển (không dùng Docker)

**Backend:**

```bash
cd backend_library
python -m venv .venv
.venv\Scripts\activate      # Windows
pip install -r requirements.txt
cd backend_library           # thư mục chứa manage.py
python manage.py migrate
python manage.py runserver 0.0.0.0:8000
```

**Frontend:**

```bash
cd frontend_library
npm install
npm run dev
```

---

## Phần 2: Hướng dẫn CI/CD

Mỗi submodule (`backend_library`, `frontend_library`) có pipeline CI/CD riêng nằm ở `.github/workflows/deploy.yml` trong chính repo của submodule đó (không phải trong repo `library-app`). Pipeline chạy trên **GitHub Actions**, trigger khi có `push` vào nhánh `main`.

### 1. Kiến trúc pipeline

Mỗi pipeline gồm 4 job:

```
gitleaks ─┐
trivy-fs ─┼──► deploy (self-hosted runner)
trivy-image ─┘
```

| Job | Chạy trên | Nhiệm vụ |
| --- | --- | --- |
| `gitleaks` | `ubuntu-latest` (GitHub-hosted) | Quét source code phát hiện secret bị lộ (API key, password, token...) bằng [gitleaks](https://github.com/gitleaks/gitleaks) |
| `trivy-fs` | `ubuntu-latest` | Quét dependency (`requirements.txt` / `package.json`) tìm lỗ hổng CVE mức `CRITICAL`/`HIGH` bằng [Trivy](https://github.com/aquasecurity/trivy) |
| `trivy-image` | `ubuntu-latest` | Build Docker image rồi quét image đó tìm CVE mức `CRITICAL`/`HIGH` |
| `deploy` | `self-hosted` (runner riêng gắn label `backend-library`/`frontend-library`) | Kéo code mới nhất, rebuild và restart đúng service tương ứng trên server |

Cả 3 job scan hiện đặt `exit-code: 0` (chỉ cảnh báo, không chặn pipeline) — đổi thành `exit-code: 1` nếu muốn pipeline fail khi phát hiện lỗ hổng.

`deploy` chỉ chạy khi cả 3 job scan hoàn tất (`needs: [gitleaks, trivy-fs, trivy-image]`), và dùng `concurrency` group để tránh 2 lần deploy chạy chồng nhau.

### 2. Job `deploy` làm gì

```yaml
DEPLOY_PATH: /home/trong/library-app   # đường dẫn checkout library-app trên VM
```

1. Vào thư mục submodule tương ứng trên server (`$DEPLOY_PATH/backend_library` hoặc `.../frontend_library`) và `git reset --hard origin/main` để lấy code mới nhất.
2. Vào `$DEPLOY_PATH` (nơi chứa `docker-compose.yml`), build lại **chỉ** image của service đó rồi `docker compose up -d <service>` — không đụng tới các service còn lại.
3. `docker image prune -f` dọn image cũ không dùng nữa.

→ Backend và frontend deploy **độc lập nhau**: push vào repo `backend_library` chỉ rebuild/restart backend, tương tự với frontend.

### 3. Chuẩn bị self-hosted runner (làm 1 lần trên server)

Trên VM triển khai (server đã cài Docker + Docker Compose):

1. Clone `library-app` kèm submodule vào đúng đường dẫn khai báo ở `DEPLOY_PATH` (mặc định `/home/trong/library-app`):
   ```bash
   git clone --recurse-submodules <url-repo-library-app> /home/trong/library-app
   cd /home/trong/library-app
   cp .env.example .env   # rồi chỉnh giá trị production
   docker compose up -d --build
   ```
2. Đăng ký self-hosted runner cho **từng** repo submodule (`backend_library`, `frontend_library`):
   - Vào repo trên GitHub → **Settings → Actions → Runners → New self-hosted runner**
   - Làm theo hướng dẫn cài đặt của GitHub (tải, giải nén, `./config.sh` với token được cấp)
   - Gắn label tương ứng để khớp với `runs-on` trong workflow:
     - Repo `backend_library` → label `backend-library`
     - Repo `frontend_library` → label `frontend-library`
   - Chạy runner as a service để tự khởi động lại cùng server:
     ```bash
     sudo ./svc.sh install
     sudo ./svc.sh start
     ```

### 4. Cách trigger deploy

Chỉ cần push (hoặc merge PR) vào nhánh `main` của repo `backend_library` hoặc `frontend_library` — không cần thao tác gì thêm trên repo `library-app`:

```bash
cd backend_library
git add .
git commit -m "..."
git push origin main
```

GitHub Actions sẽ tự chạy scan → deploy. Theo dõi tiến trình ở tab **Actions** của repo submodule tương ứng.

> Lưu ý: repo `library-app` (repo cha) chỉ giữ tham chiếu commit của submodule, không tự cập nhật khi submodule có commit mới. Nếu muốn ghim lại phiên bản submodule mới trong repo cha, chạy thêm:
> ```bash
> git submodule update --remote
> git add backend_library frontend_library
> git commit -m "chore: bump submodules"
> git push
> ```
> Việc này không ảnh hưởng tới deploy tự động (deploy đọc trực tiếp `origin/main` của submodule trên server), chỉ để đồng bộ tham chiếu.

### 5. Theo dõi & xử lý sự cố

```bash
# Trên server, xem log runner
cd ~/actions-runner   # thư mục cài runner
sudo ./svc.sh status

# Xem log service sau khi deploy
docker compose logs -f backend
docker compose logs -f frontend

# Kiểm tra job scan có phát hiện lỗ hổng không: xem tab Actions → job gitleaks/trivy-fs/trivy-image
```

---

## Phần 3: Hướng dẫn tạo tài khoản admin

Model user của dự án là **custom user model** (`api.User`, xem [models.py](backend_library/backend_library/api/models.py)), có field `role` (`admin` / `user` / `libby`). Tài khoản admin là user có `role="admin"` và `is_superuser=True`, dùng để đăng nhập vào app (frontend gọi API JWT) với quyền quản trị.

> ⚠️ **Không tạo tài khoản admin bằng cách insert thẳng dữ liệu qua pgAdmin.** Password trong bảng `api_user` được lưu dạng hash (qua `set_password()` của Django), pgAdmin không tự hash được — insert tay sẽ ra tài khoản không đăng nhập được, và cũng dễ set sai/thiếu field `role`, `is_superuser`. Luôn tạo bằng lệnh Django `createsuperuser`, chạy đúng ngay trong container `backend` — vì `CustomUserManager.create_superuser` (xem [models.py:37-41](backend_library/backend_library/api/models.py#L37-L41)) tự động set `is_superuser=True` và `role="admin"` giúp bạn.

Lệnh sẽ hỏi lần lượt: `Username`, `Email address`, `Password` (`USERNAME_FIELD = "username"`, `REQUIRED_FIELDS = ["email"]`).

### 1. Trường hợp dùng terminal VSCode (chạy local bằng Docker Compose)

Áp dụng khi bạn đang chạy hệ thống trên máy dev bằng `docker compose up` (xem [Phần 1](#phần-1-hướng-dẫn-triển-khai-dự-án)). Mở terminal VSCode ngay tại thư mục gốc `library-app`:

```bash
docker compose exec backend python manage.py createsuperuser
```

Làm theo prompt để nhập `Username`, `Email`, `Password`.

Nếu container backend chưa chạy (`docker compose ps` không thấy `library_backend`), khởi động trước:

```bash
docker compose up -d backend
```

**Nếu không chạy qua Docker** (chạy backend trực tiếp bằng venv như mục 7 ở Phần 1), mở terminal VSCode tại `backend_library/backend_library` (thư mục chứa `manage.py`), kích hoạt venv rồi chạy thẳng:

```bash
cd backend_library/backend_library
..\.venv\Scripts\activate     # Windows
python manage.py createsuperuser
```

### 2. Trường hợp dùng máy ảo (Linux server)

Áp dụng cho server production/staging — chính là VM đã cấu hình self-hosted runner ở [Phần 2](#3-chuẩn-bị-self-hosted-runner-làm-1-lần-trên-server), nơi hệ thống chạy bằng Docker Compose với `DEPLOY_PATH` mặc định `/home/trong/library-app`.

1. SSH vào server:
   ```bash
   ssh <user>@<ip-server>
   ```
2. Vào đúng thư mục deploy và chạy `createsuperuser` **bên trong container** `backend` (không chạy Python trực tiếp trên host vì server không nhất thiết có cài Python/dependency, và cần đúng DB connection mà container đang dùng):
   ```bash
   cd /home/trong/library-app
   docker compose exec backend python manage.py createsuperuser
   ```
3. Nhập `Username`, `Email`, `Password` theo prompt.

Kiểm tra lại tài khoản vừa tạo (tùy chọn):

```bash
docker compose exec backend python manage.py shell -c \
  "from api.models import User; u = User.objects.get(username='<username-vừa-tạo>'); print(u.role, u.is_superuser)"
```

Kết quả mong đợi: `admin True`.
```
