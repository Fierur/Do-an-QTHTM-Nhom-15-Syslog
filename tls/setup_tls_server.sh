#!/usr/bin/env bash
# =============================================================================
# FILE    : tls/setup_tls_server.sh
# MỤC ĐÍCH: Cài đặt Stunnel trên Syslog Server để nhận log mã hóa TLS
#           từ client qua port 6514, giải mã và chuyển vào Rsyslog port 514
# CÁCH CHẠY: sudo bash setup_tls_server.sh  (trên Syslog Server 192.168.10.100)
#
# LUỒNG TLS:
#   [Client] → Stunnel client (mã hóa) ══TLS/6514══ [Server Stunnel] → Rsyslog:514
#
# TẠI SAO dùng Stunnel thay vì imtcp TLS native?
# → imtcp TLS native cần module gtls, phải cài thêm rsyslog-gnutls,
#   cấu hình phức tạp trong rsyslog.conf và khó debug khi lỗi.
# → Stunnel là proxy độc lập: Rsyslog không biết gì về TLS, chỉ nhận
#   plaintext từ Stunnel local → Rsyslog đơn giản hơn, Stunnel đơn giản hơn
#   → Dễ debug từng thành phần khi thuyết trình.
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

ok()   { echo -e "${GREEN}OK $1${NC}"; }
fail() { echo -e "${RED}FAIL $1${NC}"; exit 1; }
info() { echo -e "${BLUE}INFO  $1${NC}"; }

# Kiểm tra root
[[ $EUID -ne 0 ]] && fail "Cần quyền root. Chạy: sudo bash $0"

CERT_DIR="/etc/stunnel/certs"
SERVER_IP="192.168.10.100"

# --------------------------------------------------------------------------- #
# TLS_PORT: 6514 là port quy ước (convention) cho Syslog over TLS
# RFC 5425 định nghĩa 6514 là port chuẩn cho TLS Syslog
# TẠI SAO không dùng 514? Vì port 514 đã dùng cho plaintext,
# giữ tách biệt giúp debug dễ hơn (biết traffic nào là TLS)
# --------------------------------------------------------------------------- #
TLS_PORT=6514
RSYSLOG_PORT=514

echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}  SETUP TLS SERVER (Stunnel) — NHÓM 15${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

###############################################################################
# BƯỚC 1: Cài đặt Stunnel4 và OpenSSL
###############################################################################
info "Cài đặt stunnel4 và openssl..."
apt-get update -qq
apt-get install -y -qq stunnel4 openssl
ok "stunnel4 và openssl đã cài"

###############################################################################
# BƯỚC 2: Tạo thư mục certificate
###############################################################################
info "Tạo thư mục certificate $CERT_DIR..."
mkdir -p "$CERT_DIR"
chmod 700 "$CERT_DIR"
ok "Thư mục $CERT_DIR đã tạo"

###############################################################################
# BƯỚC 3: Tạo CA (Certificate Authority) tự ký
#
# TẠI SAO cần CA riêng thay vì dùng CA công khai (Let's Encrypt)?
# → Lab nội bộ không có domain thật, CA công khai không cấp cert cho IP.
# → Self-signed CA đủ dùng cho lab: chúng ta TỰ ký cert cho server và client,
#   và cấu hình verify=2 (mutual TLS) → đảm bảo chỉ client có cert mới kết nối được.
# → Trong production thực tế sẽ dùng CA của công ty hoặc Let's Encrypt.
#
# TẠI SAO verify=2 (mutual TLS)?
# → verify=0: không xác thực gì (bất kỳ ai cũng kết nối được) → không an toàn
# → verify=1: server xác thực client cert nhưng không bắt buộc → vẫn có lỗ hổng
# → verify=2: XÁC THỰC 2 CHIỀU — server xác thực client VÀ client xác thực server
#   → Chỉ client có cert được ký bởi CA của chúng ta mới kết nối được
#   → Ngăn chặn kẻ tấn công giả mạo client gửi log giả lên server
###############################################################################
info "Tạo CA key và certificate..."

# Chỉ tạo mới nếu chưa có (idempotent — chạy lại không bị lỗi)
if [[ ! -f "$CERT_DIR/ca.key" ]]; then
    # Tạo CA private key (RSA 4096-bit — đủ mạnh cho lab)
    openssl genrsa -out "$CERT_DIR/ca.key" 4096 2>/dev/null
    ok "CA private key đã tạo (RSA 4096-bit)"

    # Tạo CA self-signed certificate (hiệu lực 10 năm — đủ dùng cho lab)
    openssl req -new -x509 \
        -key "$CERT_DIR/ca.key" \
        -out "$CERT_DIR/ca.crt" \
        -days 3650 \
        -subj "/C=VN/ST=HoChiMinh/O=Nhom15Lab/CN=Nhom15-CA" \
        2>/dev/null
    ok "CA certificate đã tạo (hiệu lực 10 năm)"
else
    ok "CA key/cert đã tồn tại — bỏ qua (idempotent)"
fi

###############################################################################
# BƯỚC 4: Tạo Server Certificate (ký bởi CA)
###############################################################################
info "Tạo Server certificate (ký bởi CA)..."

if [[ ! -f "$CERT_DIR/server.key" ]]; then
    # Tạo server private key
    openssl genrsa -out "$CERT_DIR/server.key" 2048 2>/dev/null

    # Tạo Certificate Signing Request (CSR)
    # CN=syslog-server phải khớp với hostname của server
    openssl req -new \
        -key "$CERT_DIR/server.key" \
        -out "$CERT_DIR/server.csr" \
        -subj "/C=VN/ST=HoChiMinh/O=Nhom15Lab/CN=syslog-server" \
        2>/dev/null

    # CA ký CSR → tạo server.crt (certificate hợp lệ)
    openssl x509 -req \
        -in "$CERT_DIR/server.csr" \
        -CA "$CERT_DIR/ca.crt" \
        -CAkey "$CERT_DIR/ca.key" \
        -CAcreateserial \
        -out "$CERT_DIR/server.crt" \
        -days 3650 \
        2>/dev/null

    rm -f "$CERT_DIR/server.csr"  # CSR không cần giữ lại
    ok "Server certificate đã tạo và ký bởi CA"
else
    ok "Server cert đã tồn tại — bỏ qua"
fi

# Đặt quyền chặt cho private key (chỉ root đọc được)
chmod 600 "$CERT_DIR/server.key" "$CERT_DIR/ca.key"
chmod 644 "$CERT_DIR/server.crt" "$CERT_DIR/ca.crt"

###############################################################################
# BƯỚC 5: Tạo cấu hình Stunnel Server
###############################################################################
info "Tạo cấu hình Stunnel Server..."

cat > /etc/stunnel/rsyslog-server.conf <<EOF
# =============================================================================
# Cấu hình Stunnel Server — Nhóm 15
# Nhận TLS từ client:$TLS_PORT → giải mã → chuyển vào Rsyslog:$RSYSLOG_PORT
# =============================================================================

# Bật debug logging của Stunnel vào syslog (mức 5 = notice)
# Giảm xuống 3 (error) khi không cần debug
syslog = yes
debug = 5

# Tắt chế độ FIPS (không cần thiết trong lab)
fips = no

# Thư mục chứa certificates
; chroot = /var/lib/stunnel4/  # Tắt chroot để dễ debug trong lab

[rsyslog-tls]
# Chế độ server (nhận kết nối đến)
; client = no  # Mặc định là server mode (không cần ghi)

# Lắng nghe TLS trên port 6514 từ mọi IP
# TẠI SAO 6514? RFC 5425 — port chuẩn cho Syslog over TLS
accept = $TLS_PORT

# Sau khi giải mã, chuyển tiếp sang Rsyslog đang chạy local trên port 514
# TẠI SAO 127.0.0.1? Vì Rsyslog và Stunnel cùng máy, không cần ra mạng
connect = 127.0.0.1:$RSYSLOG_PORT

# Certificate của server (để client xác thực server)
cert = $CERT_DIR/server.crt
key  = $CERT_DIR/server.key

# CA certificate để xác thực certificate của client
CAfile = $CERT_DIR/ca.crt

# verify=2: BẮT BUỘC xác thực certificate client (Mutual TLS)
# TẠI SAO verify=2?
# → Ngăn chặn client không có cert (ví dụ kẻ tấn công) kết nối vào server
# → Chỉ client có cert được ký bởi CA của chúng ta mới được nhận log
# → verify=0 hoặc 1 sẽ kém an toàn hơn trong môi trường thực tế
verify = 2
EOF

ok "Cấu hình Stunnel server đã tạo"

###############################################################################
# BƯỚC 6: Enable và start Stunnel
###############################################################################
info "Enable và start Stunnel4..."

# Bật Stunnel tự động khởi động
sed -i 's/^ENABLED=0/ENABLED=1/' /etc/default/stunnel4 2>/dev/null || true
# Chỉ định file cấu hình
sed -i 's|^#\?FILES=.*|FILES="/etc/stunnel/rsyslog-server.conf"|' \
    /etc/default/stunnel4 2>/dev/null || true

systemctl enable stunnel4
systemctl restart stunnel4
sleep 2

if systemctl is-active --quiet stunnel4; then
    ok "Stunnel4 đang chạy"
else
    echo -e "${RED} Stunnel4 không khởi động được${NC}"
    echo "Xem log: journalctl -u stunnel4 -n 20"
    exit 1
fi

# Kiểm tra port 6514 đã mở
if ss -tlnp | grep -q ":$TLS_PORT"; then
    ok "Port TCP/$TLS_PORT đang lắng nghe"
else
    fail "Port $TLS_PORT chưa mở — kiểm tra cấu hình stunnel"
fi

###############################################################################
# BƯỚC 7: Mở firewall
###############################################################################
info "Mở UFW port TCP/$TLS_PORT..."
ufw allow from 192.168.10.0/24 to any port "$TLS_PORT" proto tcp \
    comment "Syslog TLS (Stunnel)" 2>/dev/null || true
ok "Port TCP/$TLS_PORT đã mở cho 192.168.10.0/24"

###############################################################################
# BƯỚC 8: Hướng dẫn copy CA cert sang client
###############################################################################
echo ""
echo -e "${YELLOW}${BOLD}============================================================${NC}"
echo -e "${YELLOW}   BƯỚC TIẾP THEO — Copy CA cert sang từng client${NC}"
echo -e "${YELLOW}============================================================${NC}"
echo ""
echo -e "  Chạy lệnh SAU TRÊN SERVER để copy ca.crt sang client:"
echo ""
echo -e "  ${CYAN}# Copy sang web-client (192.168.10.101):${NC}"
echo -e "  scp $CERT_DIR/ca.crt user@192.168.10.101:/tmp/ca.crt"
echo ""
echo -e "  ${CYAN}# Copy sang app-client (192.168.10.102):${NC}"
echo -e "  scp $CERT_DIR/ca.crt user@192.168.10.102:/tmp/ca.crt"
echo ""
echo -e "  ${CYAN}# Copy sang db-client (192.168.10.103):${NC}"
echo -e "  scp $CERT_DIR/ca.crt user@192.168.10.103:/tmp/ca.crt"
echo ""
echo -e "  Sau đó trên mỗi client chạy:"
echo -e "  ${CYAN}sudo bash tls/setup_tls_client.sh <CLIENT_IP> <HOSTNAME>${NC}"
echo -e "${YELLOW}============================================================${NC}"

ok "Setup TLS Server hoàn tất!"
