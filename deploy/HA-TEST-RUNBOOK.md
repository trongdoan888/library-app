# Runbook test HA — chạy trên VM1, dùng script `~/ha3`

Yêu cầu: `~/ha3` đã được cài trên VM1 (xem `deploy/HA-3VM.md`), SSH key từ VM1
sang `pg0@192.168.111.140` (VM2) và `pg1@192.168.111.142` (VM3) đã cấu hình
sẵn (không cần gõ password). Chạy tuần tự từng bước, đọc kết quả trước khi
qua bước kế tiếp.

## Bước 0 — Baseline (xem cụm còn khoẻ không)

```bash
~/ha3 status
```
**Xem gì:** 2 dòng `pool_nodes` (đều `up`) + bảng `cluster show` (1 `primary`,
1 `standby`, `witness-3`). Nếu có gì `down`/`unreachable` → dừng lại, xử lý
trước khi chạy failover trên cụm đã yếu sẵn.

## Bước 1 — Bắt đầu ghi liên tục (đo RTO/RPO)

```bash
~/ha3 probe-start
```
**Xem gì:** dòng `probe chạy nền -> /tmp/ha3_probe.log` — xác nhận vòng lặp
ghi qua pgpool đã bắt đầu.

## Bước 2 — Giết primary

```bash
~/ha3 kill
```
**Xem gì:** dòng `>>> kill primary library_pgX @ <IP> qua ssh ...` — script
tự xác định primary hiện tại và SSH đúng máy, không cần tra IP tay.

## Bước 3 — Chờ rồi xem failover

```bash
sleep 35
~/ha3 status
```
**Xem gì:** node bị kill chuyển `down`/`failed`; node còn lại chuyển
`role=primary`, Timeline tăng thêm 1; `witness-3` đổi `Upstream` sang
primary mới.

## Bước 4 — Phòng pgpool kẹt (đã từng gặp thật)

```bash
~/ha3 kick-pgpool
```
**Xem gì:** bảng `pool_nodes` in lại — nếu primary mới đã `up` là ổn,
không cần làm gì thêm.

## Bước 5 — Hồi phục node cũ

```bash
~/ha3 recover
```
**Xem gì:** dòng `>>> start library_pgX @ <IP> qua ssh ...`.

## Bước 6 — Chờ rồi xem recovery

```bash
sleep 60
~/ha3 status
```
**Xem gì:** node cũ tự `up`/`standby ⟵ primary mới`, cùng Timeline với 2
node kia — không cần thao tác tay nhờ `repmgr` rejoin + `PGPOOL_AUTO_FAILBACK`.

## Bước 7 — Đọc kết quả RTO/RPO

```bash
~/ha3 probe-stop
~/ha3 rpo
```
**Xem gì:** `probe-stop` in 3 dòng đầu/cuối log + số lần lỗi liên tiếp
(≈ giây gián đoạn = RTO). `rpo` so `max(id)` trong DB với id cuối probe ghi
được — khớp nhau = **RPO = 0** (không mất giao dịch).

## Bước 8 — Dọn

```bash
~/ha3 clean
```

---

## Bảng ghi kết quả (điền sau mỗi lần chạy)

| Ngày chạy | Bước 0 baseline | RTO (~giây) | RPO (chênh id) | Ghi chú sự cố |
|---|---|---|---|---|
| 2026-09-18 | khoẻ (Timeline 1) | 14 | 0 (155=155) | Không cần `kick-pgpool` — auto_failback tự attach lại pg-0 sạch, không tái diễn "all backend down" |

## Tham chiếu

- Toàn bộ nội dung `~/ha3` và cách cài lại nếu mất: xem mục cuối [deploy/HA-3VM.md](HA-3VM.md).
- Danh sách sự cố đã gặp khi vận hành cụm 3-VM (NAT hairpin, ufw forward, đĩa đầy, pgpool kẹt...): mục "Sự cố thường gặp" trong cùng file.
