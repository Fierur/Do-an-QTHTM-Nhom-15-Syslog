#!/usr/bin/env bash
# =============================================================================
# FILE    : server/setup_server.sh
# MỤC ĐÍCH: Tự động cài đặt toàn bộ Syslog Server (192.168.10.100)
# CÁCH CHẠY: sudo bash setup_server.sh
# YÊU CẦU : Ubuntu 22.04 LTS, chạy với quyền root
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# Màu sắc cho terminal
# --------------------------------------------------------------------------- #
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Hàm in trạng thái bước
ok()   { echo -e "${GREEN}OK $1${NC}"; }
fail() { echo -e "${RED}FAIL $1${NC}"; exit 1; }
info() { echo -e "${BLUE}INFO  $1${NC}"; }

# --------------------------------------------------------------------------- #
# BƯỚC 0: Kiểm tra quyền root
# --------------------------------------------------------------------------- #
if [[ $EUID -ne 0 ]]; then
    fail "Script phải chạy với quyền root. Dùng: sudo bash $0"
fi

# --------------------------------------------------------------------------- #
# BƯỚC 1: Kiểm tra đúng Ubuntu 22.04
# --------------------------------------------------------------------------- #
info "Kiểm tra phiên bản hệ điều hành..."
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    if [[ "$ID" != "ubuntu" || "$VERSION_ID" != "22.04" ]]; then
        fail "Yêu cầu Ubuntu 22.04 LTS. Phát hiện: ${PRETTY_NAME:-unknown}"
    fi
    ok "Hệ điều hành: $PRETTY_NAME"
else
    fail "Không tìm thấy /etc/os-release — không xác định được OS"
fi

# --------------------------------------------------------------------------- #
# BƯỚC 2: Đặt hostname
# --------------------------------------------------------------------------- #
info "Đặt hostname = syslog-server..."
hostnamectl set-hostname syslog-server
# Cập nhật /etc/hosts để tránh lỗi DNS lookup
if ! grep -q "syslog-server" /etc/hosts; then
    echo "127.0.1.1 syslog-server" >> /etc/hosts
fi
ok "Hostname: $(hostname)"

# --------------------------------------------------------------------------- #
# BƯỚC 3: Cấu hình Static IP qua Netplan
# --------------------------------------------------------------------------- #
info "Cấu hình Static IP 192.168.10.100/24 qua Netplan..."

# Phát hiện tên interface mạng chính (thường là ens33, ens3, eth0)
IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -1)
info "Interface phát hiện: $IFACE"

# Backup file netplan cũ nếu tồn tại
NETPLAN_FILE="/etc/netplan/00-installer-config.yaml"
if [[ -f "$NETPLAN_FILE" ]]; then
    cp "$NETPLAN_FILE" "${NETPLAN_FILE}.bak.$(date +%s)"
fi

cat > "$NETPLAN_FILE" <<EOF
# Tự động sinh bởi setup_server.sh — Nhóm 15
network:
  version: 2
  ethernets:
    ${IFACE}:
      dhcp4: true
      addresses:
        - 192.168.10.100/24
    
    ens37:
      dhcp4: true
EOF

# Áp dụng cấu hình Netplan
netplan apply 2>/dev/null || true
ok "Static IP 192.168.10.100/24 đã được cấu hình (interface: $IFACE)"

# --------------------------------------------------------------------------- #
# BƯỚC 4: Cài đặt và cấu hình đồng bộ thời gian (Chrony)
# --------------------------------------------------------------------------- #
info "Cài đặt Chrony và đồng bộ thời gian..."
apt-get update -qq
apt-get install -y -qq chrony

# Đặt múi giờ Việt Nam
timedatectl set-timezone Asia/Ho_Chi_Minh

# Khởi động chrony
systemctl enable --now chrony 2>/dev/null || systemctl enable --now chronyc 2>/dev/null || true
ok "Chrony đã cài, timezone: $(timedatectl show -p Timezone --value)"

# --------------------------------------------------------------------------- #
# BƯỚC 5: Cài đặt Rsyslog
# --------------------------------------------------------------------------- #
info "Cài đặt Rsyslog..."
apt-get install -y -qq rsyslog

# Xác nhận phiên bản
RSYSLOG_VER=$(rsyslogd -v 2>&1 | head -1)
ok "Rsyslog đã cài: $RSYSLOG_VER"

# --------------------------------------------------------------------------- #
# BƯỚC 6: Tạo thư mục lưu log
# --------------------------------------------------------------------------- #
info "Tạo thư mục /var/log/remote/ và /var/log/alerts/..."
mkdir -p /var/log/remote
mkdir -p /var/log/alerts

# Cấp quyền cho syslog user
chown -R syslog:adm /var/log/remote /var/log/alerts 2>/dev/null || \
chown -R root:adm   /var/log/remote /var/log/alerts
chmod 750 /var/log/remote /var/log/alerts

ok "Thư mục /var/log/remote/ và /var/log/alerts/ đã tạo"

# --------------------------------------------------------------------------- #
# BƯỚC 7: Copy file cấu hình Rsyslog
# --------------------------------------------------------------------------- #
info "Triển khai cấu hình rsyslog.conf..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$SCRIPT_DIR/rsyslog.conf" ]]; then
    # Backup cấu hình cũ
    cp /etc/rsyslog.conf /etc/rsyslog.conf.bak.$(date +%s) 2>/dev/null || true
    cp "$SCRIPT_DIR/rsyslog.conf" /etc/rsyslog.conf
    ok "rsyslog.conf đã copy vào /etc/rsyslog.conf"
else
    fail "Không tìm thấy $SCRIPT_DIR/rsyslog.conf — đặt file vào cùng thư mục với script"
fi

# Copy cấu hình alert rules
if [[ -f "$SCRIPT_DIR/alert_rules.conf" ]]; then
    cp "$SCRIPT_DIR/alert_rules.conf" /etc/rsyslog.d/99-alerts.conf
    ok "alert_rules.conf đã copy vào /etc/rsyslog.d/99-alerts.conf"
else
    echo -e "${YELLOW}  Không tìm thấy alert_rules.conf — bỏ qua${NC}"
fi

# --------------------------------------------------------------------------- #
# BƯỚC 8: Cấu hình Logrotate
# --------------------------------------------------------------------------- #
info "Cấu hình logrotate cho /var/log/remote/..."
if [[ -f "$SCRIPT_DIR/rsyslog-remote.logrotate" ]]; then
    cp "$SCRIPT_DIR/rsyslog-remote.logrotate" /etc/logrotate.d/rsyslog-remote
    ok "Logrotate đã cấu hình"
else
    echo -e "${YELLOW}  Không tìm thấy rsyslog-remote.logrotate — bỏ qua${NC}"
fi

# --------------------------------------------------------------------------- #
# BƯỚC 9: Cấu hình Firewall UFW
# --------------------------------------------------------------------------- #
info "Cấu hình UFW firewall..."
# Cài UFW nếu chưa có
apt-get install -y -qq ufw

# Đảm bảo SSH không bị chặn trước khi bật UFW
ufw allow ssh 2>/dev/null || true

# Cho phép Syslog UDP/514 và TCP/514 từ dải mạng nội bộ
ufw allow from 192.168.10.0/24 to any port 514 proto udp comment "Syslog UDP"
ufw allow from 192.168.10.0/24 to any port 514 proto tcp comment "Syslog TCP"

# Bật UFW (--force để không hỏi xác nhận)
ufw --force enable
ok "UFW đã bật: UDP/514 và TCP/514 từ 192.168.10.0/24 được phép"

# Hiển thị trạng thái firewall
ufw status verbose

# --------------------------------------------------------------------------- #
# BƯỚC 10: Kiểm tra cấu hình và khởi động Rsyslog
# --------------------------------------------------------------------------- #
info "Kiểm tra cú pháp cấu hình Rsyslog..."
if rsyslogd -N1 -f /etc/rsyslog.conf 2>&1 | grep -q "error"; then
    fail "Cấu hình rsyslog có lỗi — kiểm tra lại /etc/rsyslog.conf"
fi
ok "Cú pháp cấu hình Rsyslog hợp lệ"

info "Khởi động Rsyslog..."
systemctl enable rsyslog
systemctl restart rsyslog
sleep 2

if systemctl is-active --quiet rsyslog; then
    ok "Rsyslog đang chạy"
else
    fail "Rsyslog không khởi động được — chạy: journalctl -u rsyslog -n 50"
fi

# --------------------------------------------------------------------------- #
# KẾT QUẢ
# --------------------------------------------------------------------------- #
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  SYSLOG SERVER ĐÃ CÀI ĐẶT THÀNH CÔNG — NHÓM 15${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "  IP Server  : 192.168.10.100"
echo -e "  Hostname   : $(hostname)"
echo -e "  Timezone   : $(timedatectl show -p Timezone --value)"
echo -e "  Log dir    : /var/log/remote/"
echo -e "  Alert dir  : /var/log/alerts/"
echo -e "  Ports      : UDP/514, TCP/514"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo "Kiểm tra log đến bằng lệnh: tail -f /var/log/remote/*/*.log"
