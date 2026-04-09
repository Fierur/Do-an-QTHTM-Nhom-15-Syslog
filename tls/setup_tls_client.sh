#!/usr/bin/env bash
# =============================================================================
# FILE    : tls/setup_tls_client.sh  [ĐÃ FIX v2]
# MỤC ĐÍCH: Cài đặt Stunnel TLS client — gửi log mã hóa đến Syslog Server
# CÁCH CHẠY: sudo bash setup_tls_client.sh <CLIENT_IP> <HOSTNAME>
# VÍ DỤ   : sudo bash setup_tls_client.sh 192.168.10.103 db-client
#
# CÁC LỖI ĐÃ FIX SO VỚI v1:
#   1. Thêm "pid = /run/stunnel4/stunnel4.pid" vào conf (bắt buộc Ubuntu 22.04)
#   2. Đảm bảo thư mục /run/stunnel4/ tồn tại trước khi start
#   3. Sửa ENABLED=1 trong /etc/default/stunnel4 (mặc định là 0 → không start)
#   4. Kiểm tra cert thực sự tồn tại trước khi ghi conf
#   5. Thêm bước verify cert sau khi tạo (openssl verify)
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# Màu terminal
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

# Tên file cert theo hostname (phải khớp chính xác)
CLIENT_KEY="${CERT_DIR}/client-${CLIENT_HOSTNAME}.key"
CLIENT_CRT="${CERT_DIR}/client-${CLIENT_HOSTNAME}.crt"
CLIENT_CSR="/tmp/client-${CLIENT_HOSTNAME}.csr"
CA_CRT="${CERT_DIR}/ca.crt"
CA_KEY="${CERT_DIR}/ca.key"   # Chỉ cần nếu ký cert ngay trên client

echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}  SETUP TLS CLIENT (Stunnel) v2 — $CLIENT_HOSTNAME${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

###############################################################################
# BƯỚC 1: Cài đặt stunnel4 và openssl
###############################################################################
info "Bước 1: Cài đặt stunnel4 và openssl..."
apt-get update -qq
apt-get install -y -qq stunnel4 openssl
ok "stunnel4 $(stunnel4 -version 2>&1 | head -1 | awk '{print $2}') đã cài"

###############################################################################
# BƯỚC 2: Tạo thư mục cert và PID
#
# FIX: Tạo /run/stunnel4/ — thư mục này cần tồn tại trước khi stunnel4 start
# vì stunnel sẽ ghi file pid vào đây. Nếu không có thư mục → start fail.
# /run/ là tmpfs (xóa khi reboot) nên cần tạo lại mỗi lần.
# Cách đúng: dùng tmpfiles.d để systemd tự tạo sau mỗi boot.
###############################################################################
info "Bước 2: Tạo thư mục cert và thư mục PID..."

mkdir -p "$CERT_DIR"
chmod 700 "$CERT_DIR"

# Tạo thư mục PID — stunnel cần ghi /run/stunnel4/stunnel4.pid
mkdir -p /run/stunnel4
chown stunnel4:stunnel4 /run/stunnel4 2>/dev/null || chown root:root /run/stunnel4
chmod 755 /run/stunnel4

# Đảm bảo /run/stunnel4/ được tạo lại sau mỗi lần reboot (dùng tmpfiles.d)
# FIX: không có dòng này → sau reboot thư mục mất → stunnel fail
if [[ ! -f /etc/tmpfiles.d/stunnel4.conf ]]; then
    echo "d /run/stunnel4 0755 stunnel4 stunnel4 -" > /etc/tmpfiles.d/stunnel4.conf 2>/dev/null || \
    echo "d /run/stunnel4 0755 root root -" > /etc/tmpfiles.d/stunnel4.conf
fi

ok "Thư mục $CERT_DIR và /run/stunnel4/ đã tạo"

###############################################################################
# BƯỚC 3: Kiểm tra CA certificate từ Server
#
# ca.crt phải được copy từ server trước (dùng scp).
# ca.key chỉ cần nếu muốn ký cert ngay trên client (không bắt buộc).
###############################################################################
info "Bước 3: Kiểm tra CA certificate..."

if [[ ! -f "$CA_CRT" ]]; then
    # Thử tìm ở /tmp (nơi scp thường để)
    if [[ -f "/tmp/ca.crt" ]]; then
        cp "/tmp/ca.crt" "$CA_CRT"
        chmod 644 "$CA_CRT"
        ok "CA cert đã copy từ /tmp/ca.crt vào $CA_CRT"
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
# FIX v1: Nếu ký cert thất bại (do thiếu ca.key), script vẫn tiếp tục
#         ghi conf → conf trỏ đến cert không tồn tại → stunnel fail.
# FIX v2: Kiểm tra cert có tồn tại VÀ hợp lệ (verify) TRƯỚC khi ghi conf.
###############################################################################
info "Bước 4: Tạo Client certificate cho $CLIENT_HOSTNAME..."

CERT_NEEDS_CREATE=false

if [[ -f "$CLIENT_KEY" && -f "$CLIENT_CRT" ]]; then
    # Cert đã có — kiểm tra còn hợp lệ không
    if openssl verify -CAfile "$CA_CRT" "$CLIENT_CRT" 2>/dev/null | grep -q "OK"; then
        ok "Client cert đã tồn tại và hợp lệ — bỏ qua tạo mới (idempotent)"
    else
        warn "Client cert tồn tại nhưng KHÔNG hợp lệ — sẽ tạo lại"
        CERT_NEEDS_CREATE=true
    fi
else
    CERT_NEEDS_CREATE=true
fi

if [[ "$CERT_NEEDS_CREATE" == "true" ]]; then
    # Tạo private key
    openssl genrsa -out "$CLIENT_KEY" 2048 2>/dev/null
    chmod 600 "$CLIENT_KEY"
    ok "Private key đã tạo: $CLIENT_KEY"

    # Tạo CSR
    openssl req -new \
        -key "$CLIENT_KEY" \
        -out "$CLIENT_CSR" \
        -subj "/C=VN/ST=HoChiMinh/O=Nhom15Lab/CN=${CLIENT_HOSTNAME}" \
        2>/dev/null
    ok "CSR đã tạo: $CLIENT_CSR"

    # Ký cert: ưu tiên ký trực tiếp nếu có ca.key
    if [[ -f "$CA_KEY" ]]; then
        openssl x509 -req \
            -in "$CLIENT_CSR" \
            -CA "$CA_CRT" \
            -CAkey "$CA_KEY" \
            -CAcreateserial \
            -out "$CLIENT_CRT" \
            -days 3650 2>/dev/null
        rm -f "$CLIENT_CSR"
        chmod 644 "$CLIENT_CRT"
        ok "Client cert đã ký bởi CA (dùng ca.key local)"
    else
        # Không có ca.key trên client — hướng dẫn ký trên server
        echo ""
        echo -e "${YELLOW}⚠️  Không có ca.key trên client — cần ký cert trên Server.${NC}"
        echo ""
        echo -e "${CYAN}  Bước 4a: Copy CSR lên Server:${NC}"
        echo -e "  scp $CLIENT_CSR $(whoami)@${SERVER_IP}:/tmp/"
        echo ""
        echo -e "${CYAN}  Bước 4b: Trên Server, ký CSR:${NC}"
        echo -e "  sudo openssl x509 -req \\"
        echo -e "    -in /tmp/client-${CLIENT_HOSTNAME}.csr \\"
        echo -e "    -CA /etc/stunnel/certs/ca.crt \\"
        echo -e "    -CAkey /etc/stunnel/certs/ca.key \\"
        echo -e "    -CAcreateserial \\"
        echo -e "    -out /tmp/client-${CLIENT_HOSTNAME}.crt \\"
        echo -e "    -days 3650"
        echo ""
        echo -e "${CYAN}  Bước 4c: Copy cert về client:${NC}"
        echo -e "  scp user@${SERVER_IP}:/tmp/client-${CLIENT_HOSTNAME}.crt /tmp/"
        echo -e "  sudo cp /tmp/client-${CLIENT_HOSTNAME}.crt $CLIENT_CRT"
        echo -e "  sudo chmod 644 $CLIENT_CRT"
        echo ""
        echo -e "${CYAN}  Bước 4d: Sau đó chạy lại script:${NC}"
        echo -e "  sudo bash $0 $CLIENT_IP $CLIENT_HOSTNAME"
        exit 1
    fi

    # FIX: Kiểm tra cert hợp lệ NGAY SAU KHI TẠO — không đợi đến lúc stunnel fail
    if openssl verify -CAfile "$CA_CRT" "$CLIENT_CRT" 2>/dev/null | grep -q "OK"; then
        ok "Xác nhận: client cert hợp lệ (verify OK)"
    else
        fail "Client cert tạo ra nhưng KHÔNG hợp lệ — kiểm tra ca.crt và ca.key có đúng cặp không"
    fi
fi

###############################################################################
# BƯỚC 5: Ghi file cấu hình Stunnel Client
#
# FIX 1: Thêm dòng "pid = /run/stunnel4/stunnel4.pid"
#         → Bắt buộc trên Ubuntu 22.04, thiếu → lỗi "no pid=pidfile specified"
# FIX 2: Ghi conf SAU KHI xác nhận cert tồn tại (không ghi conf rồi mới tạo cert)
###############################################################################
info "Bước 5: Ghi file cấu hình Stunnel client..."

cat > "$CONF_FILE" <<EOF
# =============================================================================
# Cấu hình Stunnel Client — ${CLIENT_HOSTNAME} (${CLIENT_IP}) — Nhóm 15
# Nhận plaintext từ Rsyslog:${STUNNEL_LOCAL_PORT} → mã hóa TLS → Server:${SERVER_TLS_PORT}
# Tạo bởi setup_tls_client.sh v2
# =============================================================================

# BẮT BUỘC trên Ubuntu 22.04 — systemd cần biết PID của stunnel để quản lý
# Thiếu dòng này → lỗi "no pid=pidfile specified" → stunnel không start
pid = /run/stunnel4/stunnel4.pid

# Ghi log stunnel vào syslog (xem bằng: journalctl -u stunnel4)
syslog = yes

# Mức log: 5=notice (tốt cho debug), giảm xuống 3 khi production
debug = 5

# Tắt FIPS — không cần trong môi trường lab
fips = no

[rsyslog-tls]
# client=yes: Stunnel chủ động kết nối ra ngoài (không chờ kết nối vào)
client  = yes

# Lắng nghe plaintext từ Rsyslog trên localhost:${STUNNEL_LOCAL_PORT}
# 127.0.0.1 = chỉ nhận từ chính máy này, không mở ra mạng ngoài
accept  = 127.0.0.1:${STUNNEL_LOCAL_PORT}

# Kết nối TLS đến Syslog Server
connect = ${SERVER_IP}:${SERVER_TLS_PORT}

# Certificate client (để server xác thực đây là client hợp lệ)
cert    = ${CLIENT_CRT}

# Private key tương ứng — KHÔNG chia sẻ
key     = ${CLIENT_KEY}

# CA cert để xác thực server (chống giả mạo)
CAfile  = ${CA_CRT}

# verify=2 = Mutual TLS: bắt buộc xác thực cert 2 chiều
verify  = 2
EOF

ok "File cấu hình đã ghi: $CONF_FILE"

###############################################################################
# BƯỚC 6: Sửa /etc/default/stunnel4
#
# FIX: Ubuntu mặc định ENABLED=0 → stunnel4 không bao giờ start
#      Dù có systemctl enable stunnel4 cũng vô nghĩa nếu ENABLED=0
###############################################################################
info "Bước 6: Sửa /etc/default/stunnel4 (ENABLED=1)..."

DEFAULT_FILE="/etc/default/stunnel4"

if grep -q "^ENABLED=0" "$DEFAULT_FILE" 2>/dev/null; then
    sed -i 's/^ENABLED=0/ENABLED=1/' "$DEFAULT_FILE"
    ok "Đã sửa ENABLED=0 → ENABLED=1"
elif grep -q "^ENABLED=1" "$DEFAULT_FILE" 2>/dev/null; then
    ok "ENABLED=1 đã có — bỏ qua"
else
    # Không có dòng ENABLED → thêm vào
    echo "ENABLED=1" >> "$DEFAULT_FILE"
    ok "Đã thêm ENABLED=1 vào $DEFAULT_FILE"
fi

# Đảm bảo FILES trỏ đúng conf
if grep -q "^FILES=" "$DEFAULT_FILE" 2>/dev/null; then
    sed -i "s|^FILES=.*|FILES=\"${CONF_FILE}\"|" "$DEFAULT_FILE"
else
    echo "FILES=\"${CONF_FILE}\"" >> "$DEFAULT_FILE"
fi
ok "FILES trỏ đến: $CONF_FILE"

###############################################################################
# BƯỚC 7: Append rule vào rsyslog client conf
###############################################################################
info "Bước 7: Thêm rule TLS vào /etc/rsyslog.d/99-remote.conf..."

RSYSLOG_CONF="/etc/rsyslog.d/99-remote.conf"
TLS_MARKER="# TLS-VIA-STUNNEL"

if [[ ! -f "$RSYSLOG_CONF" ]]; then
    warn "$RSYSLOG_CONF không tồn tại — chạy setup_client.sh trước"
else
    if grep -q "$TLS_MARKER" "$RSYSLOG_CONF"; then
        ok "Rule TLS đã có trong $RSYSLOG_CONF — bỏ qua (idempotent)"
    else
        cat >> "$RSYSLOG_CONF" <<RSYSLOG_RULE

# =============================================================================
${TLS_MARKER} — Thêm bởi setup_tls_client.sh v2
# Rsyslog gửi plaintext → localhost:${STUNNEL_LOCAL_PORT} → Stunnel mã hóa → Server
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
        ok "Rule TLS đã append vào $RSYSLOG_CONF"
    fi
fi

###############################################################################
# BƯỚC 8: Enable và start Stunnel4
###############################################################################
info "Bước 8: Enable và start stunnel4..."

systemctl enable stunnel4
systemctl restart stunnel4
sleep 2

if systemctl is-active --quiet stunnel4; then
    ok "stunnel4 đang ACTIVE (running)"
else
    echo ""
    echo -e "${RED}❌ stunnel4 không start — xem log chi tiết:${NC}"
    journalctl -u stunnel4 -n 20 --no-pager 2>/dev/null || true
    exit 1
fi

# Kiểm tra port 5140 đang lắng nghe
if ss -tlnp 2>/dev/null | grep -q ":${STUNNEL_LOCAL_PORT}"; then
    ok "Port ${STUNNEL_LOCAL_PORT} đang lắng nghe — Stunnel sẵn sàng"
else
    warn "Port ${STUNNEL_LOCAL_PORT} chưa thấy — đợi thêm 3 giây..."
    sleep 3
    if ss -tlnp 2>/dev/null | grep -q ":${STUNNEL_LOCAL_PORT}"; then
        ok "Port ${STUNNEL_LOCAL_PORT} đã mở"
    else
        warn "Port ${STUNNEL_LOCAL_PORT} vẫn chưa mở — kiểm tra log stunnel"
    fi
fi

###############################################################################
# BƯỚC 9: Restart Rsyslog để áp dụng rule TLS mới
###############################################################################
info "Bước 9: Restart Rsyslog..."
systemctl restart rsyslog
sleep 1
ok "Rsyslog đã restart với rule TLS mới"

###############################################################################
# KẾT QUẢ
###############################################################################
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  TLS CLIENT SETUP HOÀN TẤT v2 — $CLIENT_HOSTNAME${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "  Cert     : $CLIENT_CRT"
echo -e "  Conf     : $CONF_FILE"
echo -e "  Luồng   : Rsyslog → localhost:${STUNNEL_LOCAL_PORT} → TLS → ${SERVER_IP}:${SERVER_TLS_PORT}"
echo ""
echo -e "  Kiểm tra đầy đủ:"
echo -e "  ${CYAN}bash verify_stunnel_fix.sh${NC}"
echo -e "${GREEN}============================================================${NC}"
