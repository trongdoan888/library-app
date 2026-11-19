#!/bin/sh
# Bật/tắt NFQUEUE cho Suricata IPS (xem deploy/LOGGING.md). Chạy lại nhiều lần vẫn an toàn.
#   sudo ./deploy/suricata/ips-iptables.sh on|off|status
# Phải queue CẢ 2 chiều: chỉ --dport thì Suricata không thấy SYN/ACK, không dựng được
# phiên HTTP, rule không khớp và không chặn được gì.
# --queue-bypass: Suricata chết thì gói vẫn đi, web không sập.
# Không giữ qua reboot: sau đó `netfilter-persistent save` (gói iptables-persistent).
set -eu
[ "$(id -u)" -eq 0 ] || { echo "cần sudo" >&2; exit 1; }
Q="-j NFQUEUE --queue-num 0 --queue-bypass"
# chain + điều kiện. DOCKER-USER = nginx trong Docker (đã test); INPUT/OUTPUT = dịch vụ nghe trên host.
RULES="DOCKER-USER:--dport DOCKER-USER:--sport INPUT:--dport OUTPUT:--sport"

case "${1:-}" in
  on)
    for r in $RULES; do
      c=${r%%:*}; p=${r#*:}
      iptables -C "$c" -p tcp "$p" 80 $Q 2>/dev/null || iptables -I "$c" -p tcp "$p" 80 $Q
    done ;;
  off)
    for r in $RULES; do
      c=${r%%:*}; p=${r#*:}
      while iptables -C "$c" -p tcp "$p" 80 $Q 2>/dev/null; do iptables -D "$c" -p tcp "$p" 80 $Q; done
    done ;;
  status) iptables -S | grep NFQUEUE || echo "chưa có rule NFQUEUE" ;;
  *) echo "usage: $0 on|off|status" >&2; exit 2 ;;
esac
iptables -S | grep -c NFQUEUE | sed 's/^/số rule NFQUEUE: /'
