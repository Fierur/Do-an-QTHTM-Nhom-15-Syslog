#!/usr/bin/env bash
# =============================================================================
# FILE    : tls/setup_tls_client.sh
# MỤC ĐÍCH: Cài đặt Stunnel trên Client để gửi log mã hóa TLS đến Server
#           Rsyslog gửi đến localhost:5140 → Stunnel mã hóa → Server:6514
# CÁCH CHẠY: sudo bash setup_tls_client.sh <CLIENT_IP> <HOSTNAME>
# VÍ DỤ   : sudo bash setup_tls_client.sh 192.168.10.101 web-client
#
# LUỒNG:
#   [Rsyslog] ──plaintext──→ localhost:5140 ──TLS──→ 192.168.10.100:6514 → [Rsyslog Server]
#
# TẠI SAO Rsyslog gửi đến localhost:5140 thay vì thẳng đến server?
# → Rsyslog chỉ biết gửi plaintext TCP/UDP — không tự mã hóa TLS được
# → Stunnel đóng vai trò "TLS proxy": nhận plaintext từ Rsyslog (localhost:5140),
#   mã hóa thành TLS, và gửi lên server:6514
# → Rsyslog không cần biết gì về TLS → 2 thành phần độc lập, dễ debug riêng
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()   { echo -e "${GREEN}OK $1${NC}"; }
fail() { echo -e "${RED}FAIL $1${NC}"; exit 1; }
info() { echo -e "${BLUE}INFO  $1${NC}"; }

# --------------------------------------------------------------------------- #
# Kiểm tra tham số
# --------------------------------------------------------------------------- #
if [[ $# -lt 2 ]]; then
    echo -e "${RED}Thiếu tham số!${NC}"
    echo "Cú pháp: sudo bash $0 <CLIENT_IP> <HOSTNAME>"
    echo "Ví dụ  : sudo bash $0 192.168.10.101 web-client"
    exit 1
fi

[[ $EUID -ne 0 ]] && fail "Cần quyền root. Chạy: sudo bash $0 $*"

CLIENT_IP="$1"
CLIENT_HOSTNAME="$2"
SERVER_IP="192.168.10.100"
SERVER_TLS_PORT="6514"
STUNNEL_LOCAL_PORT="5140"   # Port local Rsyslog gửi đến Stunnel

CERT_DIR="/etc/stunnel/certs"

echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}  SETUP TLS CLIENT (Stunnel) — $CLIENT_HOSTNAME${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

###############################################################################
# BƯỚC 1: Cài đặt Stunnel4 và OpenSSL
###############################################################################
info "Cài đặt stunnel4 và openssl..."
apt-get update -qq
apt-get install -y -qq stunnel4 openssl
apt remove stunnel4
ok "stunnel4 và openssl đã cài"

###############################################################################
# BƯỚC 2: Kiểm tra CA certificate từ Server
###############################################################################
info "Kiểm tra CA certificate từ Server..."

mkdir -p "$CERT_DIR"
chmod 700 "$CERT_DIR"

if [[ ! -f "$CERT_DIR/ca.crt" ]]; then
    # Tìm ở /tmp (nơi scp thường copy vào)
    if [[ -f "/tmp/ca.crt" ]]; then
        cp "/tmp/ca.crt" "$CERT_DIR/ca.crt"
        ok "CA cert đã copy từ /tmp/ca.crt"
    else
        echo -e "${RED} Không tìm thấy ca.crt!${NC}"
        echo ""
        echo -e "${YELLOW}  Hướng dẫn: Chạy lệnh này TRÊN SERVER để copy sang client:${NC}"
        echo -e "  ${CYAN}scp /etc/stunnel/certs/ca.crt $(whoami)@${CLIENT_IP}:/tmp/ca.crt${NC}"
        echo ""
        echo -e "  Sau đó chạy lại script này."
        exit 1
    fi
else
    ok "CA cert đã tồn tại tại $CERT_DIR/ca.crt"
fi

###############################################################################
# BƯỚC 3: Tạo Client Certificate (ký bởi CA của Server)
#
# TẠI SAO mỗi client cần cert riêng?
# → Server cấu hình verify=2 (Mutual TLS): xác thực TỪNG client riêng biệt
# → Nếu 1 client bị compromise, chỉ cần thu hồi cert của client đó
#   (không ảnh hưởng client khác)
# → Tên file theo hostname: dễ quản lý khi có nhiều client
###############################################################################
info "Tạo Client certificate cho $CLIENT_HOSTNAME..."

CLIENT_KEY="$CERT_DIR/client-${CLIENT_HOSTNAME}.key"
CLIENT_CSR="$CERT_DIR/client-${CLIENT_HOSTNAME}.csr"
CLIENT_CRT="$CERT_DIR/ca.crt"

if [[ ! -f "$CLIENT_KEY" ]]; then
    # Tạo client private key
    openssl genrsa -out "$CLIENT_KEY" 2048 2>/dev/null
    ok "Client private key đã tạo"

    # Tạo CSR với CN = hostname của client
    openssl req -new \
        -key "$CLIENT_KEY" \
        -out "$CLIENT_CSR" \
        -subj "/C=VN/ST=HoChiMinh/O=Nhom15Lab/CN=${CLIENT_HOSTNAME}" \
        2>/dev/null
    ok "CSR đã tạo"

    # Ký CSR bằng CA — cần file ca.key từ server
    # QUAN TRỌNG: ca.key là private key của CA, KHÔNG copy ra ngoài trong production
    # Trong lab: copy tạm để ký, xong xóa đi
    if [[ -f "$CERT_DIR/ca.key" ]]; then
        openssl x509 -req \
            -in "$CLIENT_CSR" \
            -CA "$CERT_DIR/ca.crt" \
            -CAkey "$CERT_DIR/ca.key" \
            -CAcreateserial \
            -out "$CLIENT_CRT" \
            -days 3650 2>/dev/null
        rm -f "$CLIENT_CSR"
        ok "Client certificate đã ký bởi CA"
    else
        echo -e "${YELLOW}  Không có ca.key — cần ký cert trên Server${NC}"
        echo ""
        echo -e "  Thay thế: Copy CSR lên Server để ký, rồi copy cert về:"
        echo -e "  ${CYAN}# Trên CLIENT — copy CSR lên server:${NC}"
        echo -e "  scp $CLIENT_CSR user@${SERVER_IP}:/tmp/"
        echo ""
        echo -e "  ${CYAN}# Trên SERVER — ký CSR:${NC}"
        echo -e "  openssl x509 -req -in /tmp/client-${CLIENT_HOSTNAME}.csr \\"
        echo -e "    -CA /etc/stunnel/certs/ca.crt -CAkey /etc/stunnel/certs/ca.key \\"
        echo -e "    -CAcreateserial -out /tmp/client-${CLIENT_HOSTNAME}.crt -days 3650"
        echo ""
        echo -e "  ${CYAN}# Copy cert về CLIENT:${NC}"
        echo -e "  scp user@${SERVER_IP}:/tmp/client-${CLIENT_HOSTNAME}.crt $CLIENT_CRT"
        echo ""
        echo -e "  Sau đó chạy lại script."
        exit 1
    fi
else
    ok "Client cert đã tồn tại — bỏ qua"
fi

chmod 600 "$CLIENT_KEY"

if [[ -f "$CLIENT_CRT" ]]; then
    chmod 644 "$CLIENT_CRT"
fi

chmod 644 "$CERT_DIR/ca.crt"

###############################################################################
# BƯỚC 4: Tạo cấu hình Stunnel Client
###############################################################################
info "Tạo cấu hình Stunnel client..."

cat > /etc/stunnel/rsyslog-client.conf <<EOF
# =============================================================================
# Cấu hình Stunnel Client — $CLIENT_HOSTNAME ($CLIENT_IP) — Nhóm 15
# Nhận plaintext từ Rsyslog:$STUNNEL_LOCAL_PORT → mã hóa TLS → Server:$SERVER_TLS_PORT
# =============================================================================

syslog = yes
debug = 5
fips = no

[rsyslog-tls]
# client=yes: Stunnel hoạt động ở chế độ CLIENT (chủ động kết nối ra ngoài)
# TẠI SAO cần ghi rõ client=yes?
# → Stunnel mặc định là server mode (nhận kết nối vào)
# → client=yes đảo ngược: Stunnel NHẬN từ Rsyslog và KHỞI TẠO kết nối ra server
client = yes

# Lắng nghe plaintext từ Rsyslog trên localhost (không mở ra mạng ngoài)
# TẠI SAO 127.0.0.1:5140? Vì Rsyslog và Stunnel cùng máy
# Port 5140: tránh conflict với 514 (Rsyslog plaintext) và 6514 (TLS server)
accept = 127.0.0.1:$STUNNEL_LOCAL_PORT

# Kết nối đến Server Stunnel qua TLS
connect = ${SERVER_IP}:${SERVER_TLS_PORT}

# Certificate của client (để server xác thực)
cert = $CLIENT_CRT
key  = $CLIENT_KEY

# CA certificate để xác thực server (chống man-in-the-middle)
# TẠI SAO client cũng cần verify server?
# → Nếu không verify, kẻ tấn công có thể dựng server giả mạo để thu thập log
# → verify=2: client xác thực server cert phải được ký bởi CA của lab
CAfile = $CERT_DIR/ca.crt
verify = 2
EOF

ok "Cấu hình Stunnel client đã tạo"

###############################################################################
# BƯỚC 5: Append rule vào rsyslog.d để gửi qua Stunnel
#
# TẠI SAO APPEND thay vì ghi đè?
# → Không được sửa file gốc (rsyslog-client.conf / 99-remote.conf)
# → Thêm rule mới: *.* gửi qua localhost:5140 (Stunnel)
# → Rsyslog sẽ gửi log vừa qua Stunnel (TLS) vừa giữ các rule cũ (UDP/TCP thường)
# → Trong production thực tế sẽ comment out các rule non-TLS
###############################################################################
info "Thêm rule TLS vào /etc/rsyslog.d/99-remote.conf..."

RSYSLOG_CLIENT_CONF="/etc/rsyslog.d/99-remote.conf"
TLS_MARKER="# TLS-VIA-STUNNEL"

if [[ ! -f "$RSYSLOG_CLIENT_CONF" ]]; then
    fail "$RSYSLOG_CLIENT_CONF không tồn tại — chạy setup_client.sh trước"
fi

# Idempotent: chỉ append nếu chưa có
if grep -q "$TLS_MARKER" "$RSYSLOG_CLIENT_CONF"; then
    ok "Rule TLS đã có trong $RSYSLOG_CLIENT_CONF — bỏ qua"
else
    cat >> "$RSYSLOG_CLIENT_CONF" <<RSYSLOG_RULE

# =============================================================================
$TLS_MARKER — Thêm bởi setup_tls_client.sh
# Gửi log qua Stunnel (TLS) thay vì thẳng lên server
# Rsyslog gửi plaintext đến localhost:$STUNNEL_LOCAL_PORT
# Stunnel nhận, mã hóa TLS, và gửi đến ${SERVER_IP}:${SERVER_TLS_PORT}
# =============================================================================
*.*     action(type="omfwd"
              target="127.0.0.1"
              port="${STUNNEL_LOCAL_PORT}"
              protocol="tcp"
              queue.type="LinkedList"
              queue.filename="fwdRule_tls"
              queue.maxdiskspace="50m"
              queue.saveonshutdown="on"
              action.resumeRetryCount="-1"
              action.resumeInterval="10")
RSYSLOG_RULE
    ok "Rule TLS đã append vào $RSYSLOG_CLIENT_CONF"
fi

###############################################################################
# BƯỚC 6: Enable và start Stunnel Client
###############################################################################
info "Enable và start Stunnel4 client..."

sed -i 's/^ENABLED=0/ENABLED=1/' /etc/default/stunnel4 2>/dev/null || true
sed -i 's|^#\?FILES=.*|FILES="/etc/stunnel/rsyslog-client.conf"|' \
    /etc/default/stunnel4 2>/dev/null || true

systemctl enable stunnel4
systemctl restart stunnel4
sleep 2

if systemctl is-active --quiet stunnel4; then
    ok "Stunnel4 client đang chạy"
else
    fail "Stunnel4 không khởi động — chạy: journalctl -u stunnel4 -n 20"
fi

# Kiểm tra port 5140 đang lắng nghe local
if ss -tlnp | grep -q ":$STUNNEL_LOCAL_PORT"; then
    ok "Stunnel đang lắng nghe localhost:$STUNNEL_LOCAL_PORT"
else
    fail "Port $STUNNEL_LOCAL_PORT chưa mở — kiểm tra stunnel config"
fi

###############################################################################
# BƯỚC 7: Restart Rsyslog để áp dụng rule mới
###############################################################################
info "Khởi động lại Rsyslog..."
systemctl restart rsyslog
sleep 1
ok "Rsyslog đã restart với rule TLS mới"

###############################################################################
# Kết quả
###############################################################################
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  TLS CLIENT SETUP HOÀN TẤT — $CLIENT_HOSTNAME${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "  Luồng : Rsyslog → localhost:$STUNNEL_LOCAL_PORT → Stunnel → ${SERVER_IP}:$SERVER_TLS_PORT"
echo -e "  Cert  : $CLIENT_CRT"
echo ""
echo -e "  Test ngay:"
echo -e "  ${CYAN}logger -p user.info 'TLS test từ $CLIENT_HOSTNAME'${NC}"
echo -e "  ${CYAN}bash tls/verify_tls.sh  (chạy trên server)${NC}"
echo -e "${GREEN}============================================================${NC}"
