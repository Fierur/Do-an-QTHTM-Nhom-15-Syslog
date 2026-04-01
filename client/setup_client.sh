#!/usr/bin/env bash
# =============================================================================
# FILE    : client/setup_client.sh
# MỤC ĐÍCH: Tự động cài đặt Rsyslog Client — gửi log về Syslog Server
# CÁCH CHẠY: sudo bash setup_client.sh <IP_CLIENT> <HOSTNAME_CLIENT>
# VÍ DỤ   :
#   sudo bash setup_client.sh 192.168.10.101 web-client
#   sudo bash setup_client.sh 192.168.10.102 app-client
#   sudo bash setup_client.sh 192.168.10.103 db-client
# YÊU CẦU : Ubuntu 22.04 LTS, chạy với quyền root
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# Màu sắc terminal
# --------------------------------------------------------------------------- #
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "${GREEN}✅ $1${NC}"; }
fail() { echo -e "${RED}❌ $1${NC}"; exit 1; }
info() { echo -e "${BLUE}➡️  $1${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }

# --------------------------------------------------------------------------- #
# BƯỚC 0: Kiểm tra tham số đầu vào
# --------------------------------------------------------------------------- #
if [[ $# -lt 2 ]]; then
    echo -e "${RED}Thiếu tham số!${NC}"
    echo "Cú pháp: sudo bash $0 <IP_CLIENT> <HOSTNAME>"
    echo "Ví dụ  : sudo bash $0 192.168.10.101 web-client"
    exit 1
fi

IP_CLIENT="$1"
HOSTNAME_CLIENT="$2"
SERVER_IP="192.168.10.100"

# Kiểm tra định dạng IP cơ bản (có 4 octet phân cách bởi dấu chấm)
if ! echo "$IP_CLIENT" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
    fail "IP không hợp lệ: $IP_CLIENT"
fi

info "Cài đặt client với: IP=$IP_CLIENT | Hostname=$HOSTNAME_CLIENT"

# --------------------------------------------------------------------------- #
# BƯỚC 1: Kiểm tra quyền root
# --------------------------------------------------------------------------- #
if [[ $EUID -ne 0 ]]; then
    fail "Script phải chạy với quyền root. Dùng: sudo bash $0 $*"
fi

# --------------------------------------------------------------------------- #
# BƯỚC 2: Kiểm tra Ubuntu 22.04
# --------------------------------------------------------------------------- #
info "Kiểm tra hệ điều hành..."
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    if [[ "$ID" != "ubuntu" || "$VERSION_ID" != "22.04" ]]; then
        fail "Yêu cầu Ubuntu 22.04 LTS. Phát hiện: ${PRETTY_NAME:-unknown}"
    fi
    ok "Hệ điều hành: $PRETTY_NAME"
else
    fail "Không xác định được OS"
fi

# --------------------------------------------------------------------------- #
# BƯỚC 3: Đặt hostname
# --------------------------------------------------------------------------- #
info "Đặt hostname = $HOSTNAME_CLIENT..."
hostnamectl set-hostname "$HOSTNAME_CLIENT"

# Cập nhật /etc/hosts để hostname phân giải được cục bộ
if ! grep -q "$HOSTNAME_CLIENT" /etc/hosts; then
    echo "127.0.1.1 $HOSTNAME_CLIENT" >> /etc/hosts
fi
ok "Hostname: $(hostname)"

# --------------------------------------------------------------------------- #
# BƯỚC 4: Cấu hình Static IP qua Netplan
# --------------------------------------------------------------------------- #
info "Cấu hình Static IP $IP_CLIENT/24 qua Netplan..."

# Phát hiện interface mạng chính
IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -1)
info "Interface: $IFACE"

NETPLAN_FILE="/etc/netplan/00-installer-config.yaml"
# Backup cấu hình cũ
if [[ -f "$NETPLAN_FILE" ]]; then
    cp "$NETPLAN_FILE" "${NETPLAN_FILE}.bak.$(date +%s)"
fi

cat > "$NETPLAN_FILE" <<EOF
# Tự động sinh bởi setup_client.sh — Nhóm 15
# Client: $HOSTNAME_CLIENT ($IP_CLIENT)
network:
  version: 2
  ethernets:
    ${IFACE}:
      dhcp4: true
      addresses:
        - ${IP_CLIENT}/24

    ens37:
      dhcp4: true
EOF

netplan apply 2>/dev/null || true
ok "Static IP $IP_CLIENT/24 đã được cấu hình"

# --------------------------------------------------------------------------- #
# BƯỚC 5: Cài đặt Chrony và đồng bộ thời gian
# --------------------------------------------------------------------------- #
info "Cài đặt Chrony và đồng bộ thời gian..."
apt-get update -qq
apt-get install -y -qq chrony

timedatectl set-timezone Asia/Ho_Chi_Minh
systemctl enable --now chrony 2>/dev/null || true
ok "Chrony đã cài, timezone: $(timedatectl show -p Timezone --value)"

# --------------------------------------------------------------------------- #
# BƯỚC 6: Cài đặt Rsyslog
# --------------------------------------------------------------------------- #
info "Cài đặt Rsyslog..."
apt-get install -y -qq rsyslog
ok "Rsyslog: $(rsyslogd -v 2>&1 | head -1)"

# --------------------------------------------------------------------------- #
# BƯỚC 7: Triển khai cấu hình client
# --------------------------------------------------------------------------- #
info "Copy rsyslog-client.conf vào /etc/rsyslog.d/99-remote.conf..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$SCRIPT_DIR/rsyslog-client.conf" ]]; then
    cp "$SCRIPT_DIR/rsyslog-client.conf" /etc/rsyslog.d/99-remote.conf
    ok "rsyslog-client.conf đã triển khai"
else
    fail "Không tìm thấy $SCRIPT_DIR/rsyslog-client.conf"
fi

# Tạo thư mục queue cho disk queue (nếu rsyslog cần)
mkdir -p /var/spool/rsyslog
chown -R syslog:syslog /var/spool/rsyslog 2>/dev/null || \
chown -R root:root /var/spool/rsyslog

# --------------------------------------------------------------------------- #
# BƯỚC 8: Kiểm tra kết nối đến Syslog Server
# --------------------------------------------------------------------------- #
info "Kiểm tra kết nối đến server $SERVER_IP:514..."
if nc -zw3 "$SERVER_IP" 514 2>/dev/null; then
    ok "Kết nối TCP đến $SERVER_IP:514 thành công"
else
    warn "Không kết nối được TCP đến $SERVER_IP:514 — kiểm tra server và firewall"
fi

# --------------------------------------------------------------------------- #
# BƯỚC 9: Khởi động Rsyslog
# --------------------------------------------------------------------------- #
info "Kiểm tra cấu hình và khởi động Rsyslog..."
if rsyslogd -N1 2>&1 | grep -qi "error"; then
    fail "Cấu hình rsyslog có lỗi — chạy: rsyslogd -N1 để kiểm tra"
fi

systemctl enable rsyslog
systemctl restart rsyslog
sleep 2

if systemctl is-active --quiet rsyslog; then
    ok "Rsyslog đang chạy và gửi log đến $SERVER_IP"
else
    fail "Rsyslog không khởi động — chạy: journalctl -u rsyslog -n 50"
fi

# --------------------------------------------------------------------------- #
# KẾT QUẢ
# --------------------------------------------------------------------------- #
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  CLIENT ĐÃ CÀI ĐẶT THÀNH CÔNG — NHÓM 15${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "  Hostname   : $HOSTNAME_CLIENT"
echo -e "  IP Client  : $IP_CLIENT"
echo -e "  Syslog Srv : $SERVER_IP:514 (TCP + UDP)"
echo -e "  Config     : /etc/rsyslog.d/99-remote.conf"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo "Test gửi log: logger -p user.info 'Test từ $HOSTNAME_CLIENT'"
echo "Kiểm tra tren server: tail -f /var/log/remote/$HOSTNAME_CLIENT/syslog.log"
