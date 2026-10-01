# Kibana Dashboards

Không import NDJSON dựng sẵn ở đây — schema saved-object của Kibana Lens/
Visualize khá chi tiết và đổi giữa các version, mà không có Kibana thật để
build/test trong sandbox này thì NDJSON viết tay dễ lỗi im lặng khi import.
Thay vào đó: 4 dashboard dưới đây chỉ cần tạo Data View `library-logs-*` 1 lần
rồi thêm từng panel bằng **query có sẵn** (copy thẳng vào ô KQL của Kibana
Lens) — chắc chắn chạy đúng vì query test được ngay trong Discover trước.

Data View: Kibana → Stack Management → Data Views → Create → `library-logs-*`,
timestamp field `@timestamp`.

## 1. Application Dashboard

| Panel | Loại | KQL |
|---|---|---|
| API requests theo thời gian | Bar chart (count theo `@timestamp`) | `event.category:"web"` |
| Errors (5xx) | Metric/count | `event.category:"web" and status >= 500` |
| HTTP 4xx | Metric/count | `event.category:"web" and status >= 400 and status < 500` |
| HTTP 5xx theo endpoint | Data table (break down by `endpoint`) | `status >= 500` |

## 2. Authentication Dashboard

| Panel | Loại | KQL |
|---|---|---|
| Login success | Metric/count | `event.category:"authentication" and event.action:"login" and event.outcome:"success"` |
| Login failed | Metric/count theo thời gian | `event.category:"authentication" and event.action:"login" and event.outcome:"failure"` |
| Account locked | Metric/count | `event.action:"account_locked"` |
| Login failed theo username | Data table (break down by `username`) | `event.action:"login" and event.outcome:"failure"` |

## 3. Audit / CRUD Dashboard

| Panel | Loại | KQL |
|---|---|---|
| CREATE/UPDATE/DELETE theo thời gian | Bar chart, break down by `event.action` | `event.category:"database"` |
| Theo resource | Data table (break down by `resource`) | `event.category:"database"` |
| Theo user | Data table (break down by `user`) | `event.category:"database"` |
| Theo IP (join qua access log cùng thời điểm) | dùng bảng Access log lọc theo `user`/`endpoint` tương ứng | — |

## 4. Security Dashboard

| Panel | Loại | KQL |
|---|---|---|
| Failed login | giống Authentication Dashboard | `event.action:"login" and event.outcome:"failure"` |
| Unauthorized access (401/403) | Metric/count theo thời gian | `event.category:"web" and status:(401 or 403)` |
| Detection alerts | Kibana → Security → Alerts (built-in, không cần tự dựng panel) | — |
| Bulk delete / user resource change | giống 2 rule threshold trong `create-detection-rules.sh` | `event.action:"delete"` / `resource:"User"` |

Sau khi tạo 4 dashboard, lưu lại (Save) — chúng đọc dữ liệu thực từ
Elasticsearch, tự cập nhật khi có log mới, đúng yêu cầu mục XI.
