#!/usr/bin/env bash
# =============================================================================
# FILE    : tls/setup_tls_client.sh  [FIXED v3]
# MỤC ĐÍCH: Cài đặt Stunnel TLS client — gửi log mã hóa đến Syslog Server
# CÁCH CHẠY: sudo bash setup_tls_client.sh <CLIENT_IP> <HOSTNAME>
# VÍ DỤ   : sudo bash setup_tls_client.sh 192.168.10.103 db-client
#
# LỊCH SỬ FIX:
#   v1 → v2: thêm pid=, ENABLED=1, verify cert trước khi ghi conf
#   v2 → v3: [BUG NGHIÊM TRỌNG]
#     - Xóa dòng "apt remove stunnel4" ở Bước 1 (khiến binary bị xóa sau cài)
#     - Sửa CLIENT_CRT từ "ca.crt" → "client-${HOSTNAME}.crt" (gán nhầm biến)
#     - Xóa định nghĩa hàm trùng lặp ok/fail/info
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# Màu terminal — định nghĩa MỘT LẦN DUY NHẤT
# --------------------------------------------------------------------------- #
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()   { echo -e "${GREEN}✅ $1${NC}"; }
fail() { echo -e "${RED}❌ $1${NC}"; exit 1; }
info() { echo -e "${BLUE}➡️  $1${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }

# --------------------------------------------------------------------------- #
# Kiểm tra tham số và quyền root
# --------------------------------------------------------------------------- #
if [[ $# -lt 2 ]]; then
    echo -e "${RED}Thiếu tham số!${NC}"
    echo "Cú pháp: sudo bash $0 <CLIENT_IP> <HOSTNAME>"
    echo "Ví dụ  : sudo bash $0 192.168.10.103 db-client"
    exit 1
fi

[[ $EUID -ne 0 ]] && fail "Cần quyền root. Chạy: sudo bash $0 $*"

CLIENT_IP="$1"
CLIENT_HOSTNAME="$2"
SERVER_IP="192.168.10.100"
SERVER_TLS_PORT="6514"
STUNNEL_LOCAL_PORT="5140"

CERT_DIR="/etc/stunnel/certs"
CONF_FILE="/etc/stunnel/rsyslog-client.conf"

# Tên file cert — khai báo MỘT LẦN, không gán lại bên dưới
CA_CRT="${CERT_DIR}/ca.crt"
CA_KEY="${CERT_DIR}/ca.key"
CLIENT_KEY="${CERT_DIR}/client-${CLIENT_HOSTNAME}.key"
CLIENT_CRT="${CERT_DIR}/client-${CLIENT_HOSTNAME}.crt"   # FIX v3: không phải ca.crt
CLIENT_CSR="/tmp/client-${CLIENT_HOSTNAME}.csr"          # FIX v3: để ở /tmp, không trong CERT_DIR

echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}  SETUP TLS CLIENT v3 — $CLIENT_HOSTNAME ($CLIENT_IP)${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

###############################################################################
# BƯỚC 1: Cài đặt stunnel4 và openssl
#
# FIX v3: ĐÃ XÓA dòng "apt remove stunnel4" khỏi đây.
# Dòng đó khiến binary stunnel4 bị gỡ ngay sau khi cài → service không start.
# Đây là nguyên nhân phải "apt remove rồi restart" mới chạy được.
###############################################################################
info "Bước 1: Cài đặt stunnel4 và openssl..."
apt-get update -qq
apt-get install -y -qq stunnel4 openssl
ok "stunnel4 $(stunnel4 -version 2>&1 | head -1 | awk '{print $2}') đã cài"

###############################################################################
# BƯỚC 2: Tạo thư mục cert và thư mục PID
#
# /run/stunnel4/ bị xóa sau mỗi lần reboot (vì /run là tmpfs — RAM disk).
# Dùng tmpfiles.d để systemd tự tạo lại sau mỗi boot.
###############################################################################
info "Bước 2: Tạo thư mục cert và thư mục PID..."

mkdir -p "$CERT_DIR"
chmod 700 "$CERT_DIR"

# Tạo thư mục PID ngay bây giờ (cho lần chạy hiện tại)
mkdir -p /run/stunnel4
chown stunnel4:stunnel4 /run/stunnel4 2>/dev/null || chown root:root /run/stunnel4
chmod 755 /run/stunnel4

# Đăng ký với tmpfiles.d để tạo lại sau mỗi reboot
if [[ ! -f /etc/tmpfiles.d/stunnel4.conf ]]; then
    echo "d /run/stunnel4 0755 stunnel4 stunnel4 -" \
        > /etc/tmpfiles.d/stunnel4.conf 2>/dev/null || \
    echo "d /run/stunnel4 0755 root root -" \
        > /etc/tmpfiles.d/stunnel4.conf
fi

ok "Thư mục $CERT_DIR và /run/stunnel4/ đã tạo"

###############################################################################
# BƯỚC 3: Kiểm tra CA certificate
#
# ca.crt phải được copy từ server trước khi chạy script này:
#   scp /etc/stunnel/certs/ca.crt USER@CLIENT_IP:/tmp/ca.crt
###############################################################################
info "Bước 3: Kiểm tra CA certificate..."

if [[ ! -f "$CA_CRT" ]]; then
    if [[ -f "/tmp/ca.crt" ]]; then
        cp "/tmp/ca.crt" "$CA_CRT"
        chmod 644 "$CA_CRT"
        ok "CA cert đã copy từ /tmp/ca.crt → $CA_CRT"
    else
        echo ""
        echo -e "${RED}❌ Không tìm thấy ca.crt!${NC}"
        echo ""
        echo -e "${YELLOW}  Chạy lệnh này TRÊN SERVER để copy sang client:${NC}"
        echo -e "  ${CYAN}scp /etc/stunnel/certs/ca.crt $(whoami)@${CLIENT_IP}:/tmp/ca.crt${NC}"
        echo ""
        echo -e "  Sau đó chạy lại script này."
        exit 1
    fi
else
    ok "CA cert đã có tại $CA_CRT"
fi

###############################################################################
# BƯỚC 4: Tạo Client Certificate
#
# FIX v3: CLIENT_CRT = client-${HOSTNAME}.crt  (KHÔNG PHẢI ca.crt)
# Bug cũ: CLIENT_CRT="$CERT_DIR/ca.crt" → stunnel dùng CA cert làm client cert
#         → server reject → TLS handshake fail → không có traffic qua port 6514
###############################################################################
info "Bước 4: Tạo Client certificate cho $CLIENT_HOSTNAME..."

CERT_NEEDS_CREATE=false

if [[ -f "$CLIENT_KEY" && -f "$CLIENT_CRT" ]]; then
    # Cert đã có — xác minh còn hợp lệ không (đúng CA, chưa hết hạn)
    if openssl verify -CAfile "$CA_CRT" "$CLIENT_CRT" 2>/dev/null | grep -q "OK"; then
        ok "Client cert đã tồn tại và hợp lệ — bỏ qua (idempotent)"
    else
        warn "Client cert tồn tại nhưng verify FAIL — sẽ tạo lại"
        CERT_NEEDS_CREATE=true
    fi
else
    CERT_NEEDS_CREATE=true
fi

if [[ "$CERT_NEEDS_CREATE" == "true" ]]; then

    # Tạo private key RSA 2048-bit
    openssl genrsa -out "$CLIENT_KEY" 2048 2>/dev/null
    chmod 600 "$CLIENT_KEY"
    ok "Private key: $CLIENT_KEY"

    # Tạo CSR (Certificate Signing Request)
    openssl req -new \
        -key "$CLIENT_KEY" \
        -out "$CLIENT_CSR" \
        -subj "/C=VN/ST=HoChiMinh/O=Nhom15Lab/CN=${CLIENT_HOSTNAME}" \
        2>/dev/null
    ok "CSR: $CLIENT_CSR"

    # Ký cert bằng CA
    if [[ -f "$CA_KEY" ]]; then
        # CA key có sẵn trên client → ký luôn
        openssl x509 -req \
            -in "$CLIENT_CSR" \
            -CA "$CA_CRT" \
            -CAkey "$CA_KEY" \
            -CAcreateserial \
            -out "$CLIENT_CRT" \
            -days 3650 2>/dev/null
        rm -f "$CLIENT_CSR"
        chmod 644 "$CLIENT_CRT"
        ok "Client cert đã ký bởi CA local"
    else
        # Không có CA key → phải ký trên server
        echo ""
        warn "Không có ca.key trên client — cần ký cert trên Server."
        echo ""
        echo -e "${CYAN}  Bước 4a — Copy CSR lên Server:${NC}"
        echo -e "  scp $CLIENT_CSR $(whoami)@${SERVER_IP}:/tmp/"
        echo ""
        echo -e "${CYAN}  Bước 4b — Trên Server, chạy:${NC}"
        echo -e "  sudo openssl x509 -req \\"
        echo -e "      -in /tmp/client-${CLIENT_HOSTNAME}.csr \\"
        echo -e "      -CA /etc/stunnel/certs/ca.crt \\"
        echo -e "      -CAkey /etc/stunnel/certs/ca.key \\"
        echo -e "      -CAcreateserial \\"
        echo -e "      -out /tmp/client-${CLIENT_HOSTNAME}.crt \\"
        echo -e "      -days 3650"
        echo ""
        echo -e "${CYAN}  Bước 4c — Copy cert về client:${NC}"
        echo -e "  scp $(whoami)@${SERVER_IP}:/tmp/client-${CLIENT_HOSTNAME}.crt /tmp/"
        echo -e "  sudo cp /tmp/client-${CLIENT_HOSTNAME}.crt ${CLIENT_CRT}"
        echo -e "  sudo chmod 644 ${CLIENT_CRT}"
        echo ""
        echo -e "${CYAN}  Bước 4d — Chạy lại script:${NC}"
        echo -e "  sudo bash $0 $CLIENT_IP $CLIENT_HOSTNAME"
        exit 1
    fi

    # Verify cert ngay sau khi tạo — không để stunnel phát hiện lỗi sau
    if openssl verify -CAfile "$CA_CRT" "$CLIENT_CRT" 2>/dev/null | grep -q "OK"; then
        ok "Verify cert: OK"
    else
        fail "Cert tạo ra nhưng verify FAIL — ca.crt và ca.key không cùng cặp?"
    fi
fi

###############################################################################
# BƯỚC 5: Ghi file cấu hình Stunnel Client
#
# Ghi TOÀN BỘ conf mới (không append) để tránh conf cũ bị lỗi còn sót.
# Biến ${CLIENT_CRT} lúc này đã chắc chắn là client-${HOSTNAME}.crt đúng.
###############################################################################
info "Bước 5: Ghi cấu hình Stunnel client → $CONF_FILE..."

cat > "$CONF_FILE" <<EOF
# =============================================================================
# Cấu hình Stunnel Client — ${CLIENT_HOSTNAME} (${CLIENT_IP})
# Tạo bởi setup_tls_client.sh v3
# =============================================================================

# BẮT BUỘC trên Ubuntu 22.04: systemd cần file pid để quản lý process
# Thiếu dòng này → lỗi "no pid=pidfile specified" → không start được
pid = /run/stunnel4/stunnel4.pid

syslog = yes
debug = 5
fips = no

[rsyslog-tls]
# client=yes: Stunnel chủ động kết nối ra ngoài đến server
# Ngược lại (server mode): Stunnel chờ kết nối vào — sai với vai trò client
client  = yes

# Lắng nghe plaintext từ Rsyslog gửi đến localhost:${STUNNEL_LOCAL_PORT}
# Chỉ nhận từ 127.0.0.1 — không expose ra mạng ngoài
accept  = 127.0.0.1:${STUNNEL_LOCAL_PORT}

# Kết nối TLS đến Stunnel Server
connect = ${SERVER_IP}:${SERVER_TLS_PORT}

# Client certificate — để server xác thực đây là client hợp lệ
# FIX v3: đây là client-${CLIENT_HOSTNAME}.crt, KHÔNG PHẢI ca.crt
cert    = ${CLIENT_CRT}

# Private key tương ứng với cert trên
key     = ${CLIENT_KEY}

# CA cert để client xác thực server (chống giả mạo server)
CAfile  = ${CA_CRT}

# Mutual TLS: cả 2 bên đều phải xuất trình cert hợp lệ
verify  = 2
EOF

ok "Cấu hình đã ghi: $CONF_FILE"

# Hiện nội dung để xác nhận đường dẫn cert đúng
echo ""
echo -e "  ${CYAN}Kiểm tra nhanh đường dẫn cert trong conf:${NC}"
grep -E "^(cert|key|CAfile)" "$CONF_FILE" | while IFS= read -r line; do
    FPATH=$(echo "$line" | awk '{print $NF}')
    if [[ -f "$FPATH" ]]; then
        echo -e "  ${GREEN}✅ $line${NC}"
    else
        echo -e "  ${RED}❌ FILE KHÔNG TỒN TẠI: $line${NC}"
    fi
done
echo ""

###############################################################################
# BƯỚC 6: Bật stunnel4 trong /etc/default/stunnel4
#
# Ubuntu mặc định ENABLED=0 → stunnel4 service không bao giờ start
# dù đã chạy systemctl enable stunnel4
###############################################################################
info "Bước 6: Bật stunnel4 (ENABLED=1)..."

DEFAULT_FILE="/etc/default/stunnel4"

if grep -q "^ENABLED=0" "$DEFAULT_FILE" 2>/dev/null; then
    sed -i 's/^ENABLED=0/ENABLED=1/' "$DEFAULT_FILE"
    ok "ENABLED: 0 → 1"
elif grep -q "^ENABLED=1" "$DEFAULT_FILE" 2>/dev/null; then
    ok "ENABLED=1 đã có"
else
    echo "ENABLED=1" >> "$DEFAULT_FILE"
    ok "Đã thêm ENABLED=1"
fi

# Trỏ FILES đến đúng file conf
if grep -q "^FILES=" "$DEFAULT_FILE" 2>/dev/null; then
    sed -i "s|^FILES=.*|FILES=\"${CONF_FILE}\"|" "$DEFAULT_FILE"
else
    echo "FILES=\"${CONF_FILE}\"" >> "$DEFAULT_FILE"
fi
ok "FILES → $CONF_FILE"

###############################################################################
# BƯỚC 7: Append rule TLS vào rsyslog (idempotent)
###############################################################################
info "Bước 7: Thêm rule TLS vào rsyslog..."

RSYSLOG_CONF="/etc/rsyslog.d/99-remote.conf"
TLS_MARKER="# TLS-VIA-STUNNEL"

if [[ ! -f "$RSYSLOG_CONF" ]]; then
    warn "$RSYSLOG_CONF không tồn tại — chạy setup_client.sh trước"
elif grep -q "$TLS_MARKER" "$RSYSLOG_CONF"; then
    ok "Rule TLS đã có — bỏ qua (idempotent)"
else
    cat >> "$RSYSLOG_CONF" <<RSYSLOG_RULE

# =============================================================================
${TLS_MARKER} — setup_tls_client.sh v3
# Rsyslog → localhost:${STUNNEL_LOCAL_PORT} → [Stunnel mã hóa TLS] → ${SERVER_IP}:${SERVER_TLS_PORT}
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
    ok "Rule TLS đã thêm vào $RSYSLOG_CONF"
fi

###############################################################################
# BƯỚC 8: Khởi động Stunnel và Rsyslog
###############################################################################
info "Bước 8: Khởi động stunnel4..."

systemctl enable stunnel4
systemctl restart stunnel4
sleep 2

if systemctl is-active --quiet stunnel4; then
    ok "stunnel4 đang ACTIVE"
else
    echo ""
    echo -e "${RED}❌ stunnel4 không start — log chi tiết:${NC}"
    journalctl -u stunnel4 -n 30 --no-pager 2>/dev/null || true
    echo ""
    echo -e "${YELLOW}Các nguyên nhân thường gặp:${NC}"
    echo -e "  1. /run/stunnel4/ không tồn tại: sudo mkdir -p /run/stunnel4"
    echo -e "  2. File cert không đúng: grep -E '^(cert|key|CAfile)' $CONF_FILE"
    echo -e "  3. ENABLED chưa sửa: grep ENABLED /etc/default/stunnel4"
    exit 1
fi

# Xác nhận port 5140 đang lắng nghe
sleep 1
if ss -tlnp 2>/dev/null | grep -q ":${STUNNEL_LOCAL_PORT}"; then
    ok "Port ${STUNNEL_LOCAL_PORT} đang lắng nghe ✓"
else
    warn "Port ${STUNNEL_LOCAL_PORT} chưa thấy sau 3 giây — kiểm tra log stunnel"
fi

info "Bước 9: Restart rsyslog với rule TLS mới..."
systemctl restart rsyslog
sleep 1
ok "rsyslog đã restart"

###############################################################################
# KẾT QUẢ — tóm tắt để xác nhận mọi thứ đúng
###############################################################################
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  SETUP HOÀN TẤT v3 — $CLIENT_HOSTNAME${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "  Client cert : $CLIENT_CRT"
echo -e "  Conf file   : $CONF_FILE"
echo -e "  Luồng       : Rsyslog → :${STUNNEL_LOCAL_PORT} → TLS → ${SERVER_IP}:${SERVER_TLS_PORT}"
echo ""
echo -e "  ${CYAN}Test ngay:${NC}"
echo -e "  logger -p auth.info 'TLS_TEST from $CLIENT_HOSTNAME'"
echo ""
echo -e "  ${CYAN}Kiểm tra trên server:${NC}"
echo -e "  grep 'TLS_TEST' /var/log/remote/$CLIENT_HOSTNAME/syslog.log"
echo -e "${GREEN}============================================================${NC}"
