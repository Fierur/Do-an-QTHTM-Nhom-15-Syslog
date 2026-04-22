#!/usr/bin/env bash
# =============================================================================
# FILE    : tls/setup_tls_client.sh  (version 3 — viết lại hoàn toàn)
# MỤC ĐÍCH: Cài đặt Stunnel TLS client — nhận cert đã ký bởi server
# CÁCH CHẠY: sudo bash setup_tls_client.sh <CLIENT_IP> <HOSTNAME>
# VÍ DỤ   : sudo bash setup_tls_client.sh 192.168.10.101 web-client
#
# YÊU CẦU TRƯỚC KHI CHẠY:
#   1. Cert đã được ký bởi server: sudo bash server/sign_client_certs.sh
#   2. /etc/stunnel/certs/client-HOSTNAME.crt phải tồn tại và hợp lệ
#
# THAY ĐỔI SO VỚI v2 (4 bug đã fix):
#   FIX 1: Không còn "apt remove stunnel4" — stunnel4 được giữ lại sau khi cài
#   FIX 2: CLIENT_CRT = client-HOSTNAME.crt (không phải ca.crt)
#   FIX 3: Hàm ok/fail/info/warn khai báo đúng 1 lần
#   FIX 4: STUNNEL_LOCAL_PORT khai báo đúng 1 lần
#   FIX KIẾN TRÚC: Script không tự tạo/ký cert — chỉ dùng cert đã có
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# Khai báo hàm màu terminal — CHỈ 1 LẦN (FIX BUG 3)
# --------------------------------------------------------------------------- #
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "${GREEN}✅ $1${NC}"; }
fail() { echo -e "${RED}❌ $1${NC}"; exit 1; }
info() { echo -e "${BLUE}➡  $1${NC}"; }
warn() { echo -e "${YELLOW}⚠  $1${NC}"; }

# --------------------------------------------------------------------------- #
# Kiểm tra tham số và quyền root
# --------------------------------------------------------------------------- #
if [[ $# -lt 2 ]]; then
    echo -e "${RED}Thiếu tham số!${NC}"
    echo "Cú pháp: sudo bash $0 <CLIENT_IP> <HOSTNAME>"
    echo "Ví dụ  : sudo bash $0 192.168.10.101 web-client"
    exit 1
fi

[[ $EUID -ne 0 ]] && fail "Cần quyền root. Chạy: sudo bash $0 $*"

# --------------------------------------------------------------------------- #
# Khai báo biến — CHỈ 1 LẦN, KHÔNG khai báo lại ở bất kỳ bước nào (FIX BUG 4)
# --------------------------------------------------------------------------- #
CLIENT_IP="$1"
CLIENT_HOSTNAME="$2"
SERVER_IP="192.168.10.100"
SERVER_TLS_PORT="6514"
STUNNEL_LOCAL_PORT="5140"    # FIX BUG 4: khai báo đúng 1 lần

CERT_DIR="/etc/stunnel/certs"
CONF_FILE="/etc/stunnel/rsyslog-client.conf"

# FIX BUG 2: CLIENT_CRT là client cert, KHÔNG phải ca.crt
CLIENT_KEY="${CERT_DIR}/client-${CLIENT_HOSTNAME}.key"
CLIENT_CRT="${CERT_DIR}/client-${CLIENT_HOSTNAME}.crt"   # ← ĐÚNG
CA_CRT="${CERT_DIR}/ca.crt"
# KHÔNG khai báo lại các biến này ở bất kỳ bước nào bên dưới

echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   SETUP TLS CLIENT v3 — ${CLIENT_HOSTNAME}$(printf '%*s' $((30 - ${#CLIENT_HOSTNAME})) '')║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# --------------------------------------------------------------------------- #
# BƯỚC 1: Kiểm tra Ubuntu 22.04
# --------------------------------------------------------------------------- #
info "Bước 1: Kiểm tra hệ điều hành..."
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    if [[ "$ID" != "ubuntu" || "$VERSION_ID" != "22.04" ]]; then
        fail "Yêu cầu Ubuntu 22.04 LTS. Phát hiện: ${PRETTY_NAME:-unknown}"
    fi
    ok "OS: $PRETTY_NAME"
else
    fail "Không xác định được OS"
fi

# --------------------------------------------------------------------------- #
# BƯỚC 2: Cài stunnel4 — idempotent, TUYỆT ĐỐI không remove (FIX BUG 1)
#
# TẠI SAO kiểm tra command -v thay vì cứ apt-get install?
# → apt-get install luôn chạy apt-get update (chậm, tốn bandwidth)
# → Nếu đã cài rồi → bỏ qua hoàn toàn, chạy nhanh hơn khi idempotent
# --------------------------------------------------------------------------- #
info "Bước 2: Kiểm tra/cài stunnel4..."
if ! command -v stunnel4 &>/dev/null; then
    apt-get update -qq
    apt-get install -y -qq stunnel4 openssl
    ok "stunnel4 đã cài: $(stunnel4 -version 2>&1 | head -1)"
else
    ok "stunnel4 đã có: $(stunnel4 -version 2>&1 | head -1) — bỏ qua cài lại"
fi
# TUYỆT ĐỐI KHÔNG có "apt remove stunnel4" ở đây hoặc bất kỳ đâu trong file

# --------------------------------------------------------------------------- #
# BƯỚC 3: Tạo thư mục cert và thư mục PID
#
# TẠI SAO cần /run/stunnel4/?
# → stunnel4 ghi PID vào /run/stunnel4/stunnel4.pid khi start
# → /run/ là tmpfs (xóa khi reboot) → cần tạo lại mỗi lần boot
# → tmpfiles.d là cơ chế systemd để tự tạo lại thư mục sau reboot
# --------------------------------------------------------------------------- #
info "Bước 3: Tạo thư mục cert và PID..."

mkdir -p "$CERT_DIR"
chmod 700 "$CERT_DIR"

# Tạo thư mục PID runtime
mkdir -p /run/stunnel4
# Ưu tiên chown về user stunnel4 nếu tồn tại, fallback về root
chown stunnel4:stunnel4 /run/stunnel4 2>/dev/null || chown root:root /run/stunnel4
chmod 755 /run/stunnel4

# Đảm bảo /run/stunnel4/ tự tạo lại sau mỗi reboot
if [[ ! -f /etc/tmpfiles.d/stunnel4.conf ]]; then
    # Thử tạo với user stunnel4, fallback root nếu user không tồn tại
    echo "d /run/stunnel4 0755 stunnel4 stunnel4 -" \
        > /etc/tmpfiles.d/stunnel4.conf 2>/dev/null || \
    echo "d /run/stunnel4 0755 root root -" \
        > /etc/tmpfiles.d/stunnel4.conf
fi

ok "Thư mục $CERT_DIR và /run/stunnel4/ đã sẵn sàng"

# --------------------------------------------------------------------------- #
# BƯỚC 4: Kiểm tra cert bắt buộc tồn tại VÀ hợp lệ (FIX BUG KIẾN TRÚC)
#
# TẠI SAO script KHÔNG tự tạo cert ở đây?
# → Ký cert cần ca.key — ca.key CHỈ có trên server, không trên client
# → Nếu cố tạo cert không có ca.key → cert sẽ self-signed → verify fail
# → Giải pháp đúng: server ký trước (sign_client_certs.sh), client chỉ dùng
#
# 3 file bắt buộc phải tồn tại trước bước này:
#   - CLIENT_KEY: private key của client (tạo bởi sign_client_certs.sh)
#   - CLIENT_CRT: cert đã ký bởi CA (copy bởi sign_client_certs.sh)
#   - CA_CRT: CA cert để xác thực server (copy bởi sign_client_certs.sh)
# --------------------------------------------------------------------------- #
info "Bước 4: Kiểm tra cert bắt buộc..."

CERT_ERROR=false

# Kiểm tra CA cert
if [[ ! -f "$CA_CRT" ]]; then
    echo -e "${RED}❌ Thiếu CA cert: $CA_CRT${NC}"
    CERT_ERROR=true
fi

# Kiểm tra client private key
if [[ ! -f "$CLIENT_KEY" ]]; then
    echo -e "${RED}❌ Thiếu client key: $CLIENT_KEY${NC}"
    CERT_ERROR=true
fi

# Kiểm tra client cert tồn tại VÀ hợp lệ (được ký bởi CA đúng)
if [[ ! -f "$CLIENT_CRT" ]]; then
    echo -e "${RED}❌ Thiếu client cert: $CLIENT_CRT${NC}"
    CERT_ERROR=true
elif [[ -f "$CA_CRT" ]]; then
    # Verify: cert phải được ký bởi CA hiện tại, không phải CA cũ
    if ! openssl verify -CAfile "$CA_CRT" "$CLIENT_CRT" 2>/dev/null | grep -q "OK"; then
        echo -e "${RED}❌ Client cert tồn tại nhưng KHÔNG hợp lệ (sai CA hoặc đã hết hạn)${NC}"
        CERT_ERROR=true
    fi
fi

if [[ "$CERT_ERROR" == "true" ]]; then
    echo ""
    echo -e "${YELLOW}${BOLD}  Giải pháp: Chạy lệnh này TRÊN SERVER để ký cert tự động:${NC}"
    echo -e "  ${CYAN}sudo bash server/sign_client_certs.sh${NC}"
    echo ""
    echo -e "  Sau đó chạy lại script này."
    exit 1
fi

ok "CLIENT_KEY  : $CLIENT_KEY ✓"
ok "CLIENT_CRT  : $CLIENT_CRT ✓ (verify OK)"
ok "CA_CRT      : $CA_CRT ✓"

# --------------------------------------------------------------------------- #
# BƯỚC 5: Ghi file cấu hình Stunnel client
#
# QUAN TRỌNG: cert và key PHẢI trỏ đúng client-HOSTNAME.crt và .key
# KHÔNG dùng ca.crt làm cert — đây là FIX BUG 2 quan trọng nhất
# --------------------------------------------------------------------------- #
info "Bước 5: Ghi cấu hình Stunnel client..."

cat > "$CONF_FILE" <<EOF
# =============================================================================
# Cấu hình Stunnel Client — ${CLIENT_HOSTNAME} (${CLIENT_IP}) — Nhóm 15
# Luồng: Rsyslog → localhost:${STUNNEL_LOCAL_PORT} → TLS → Server:${SERVER_TLS_PORT}
# Tạo bởi setup_tls_client.sh v3
# =============================================================================

# BẮT BUỘC trên Ubuntu 22.04 — systemd đọc PID từ file này để quản lý service
# Thiếu dòng này → lỗi "no pid=pidfile specified" → stunnel4 không start
pid = /run/stunnel4/stunnel4.pid

# Log stunnel vào syslog (xem bằng: journalctl -u stunnel4)
syslog = yes

# Mức log: 5=notice (debug), 3=error (production)
debug = 5

# Tắt FIPS — không cần trong môi trường lab
fips = no

[rsyslog-tls]
# client=yes: Stunnel chủ động kết nối ra ngoài (không chờ kết nối vào)
# TẠI SAO cần client=yes? Vì đây là phía gửi, không phải phía nhận
client  = yes

# Lắng nghe plaintext từ Rsyslog trên localhost
# 127.0.0.1 = chỉ nhận từ chính máy này, không lộ ra mạng ngoài
accept  = 127.0.0.1:${STUNNEL_LOCAL_PORT}

# Kết nối TLS đến Syslog Server port 6514
connect = ${SERVER_IP}:${SERVER_TLS_PORT}

# FIX BUG 2: Dùng client cert (KHÔNG phải ca.crt)
# cert = certificate của client để server xác thực danh tính client
cert    = ${CLIENT_CRT}

# key = private key tương ứng với cert — KHÔNG bao giờ chia sẻ
key     = ${CLIENT_KEY}

# CAfile = CA cert để client xác thực cert của server (chống giả mạo server)
CAfile  = ${CA_CRT}

# verify=2 = Mutual TLS: cả 2 chiều đều bắt buộc xác thực cert
# TẠI SAO verify=2?
# → verify=0: không xác thực → kẻ tấn công giả mạo server được
# → verify=1: server xác thực client nhưng client không xác thực server
# → verify=2: cả 2 chiều → an toàn nhất, phù hợp production
verify  = 2
EOF

ok "Cấu hình đã ghi: $CONF_FILE"

# --------------------------------------------------------------------------- #
# BƯỚC 6: Sửa /etc/default/stunnel4
#
# TẠI SAO Ubuntu mặc định ENABLED=0?
# → Ubuntu cài stunnel4 nhưng không start tự động vì không biết bạn muốn
#   dùng config nào. Phải bật ENABLED=1 thủ công.
# → Dù có systemctl enable stunnel4 → vẫn không start nếu ENABLED=0
# --------------------------------------------------------------------------- #
info "Bước 6: Sửa /etc/default/stunnel4..."

DEFAULT_FILE="/etc/default/stunnel4"

# Sửa ENABLED=0 → ENABLED=1
if grep -q "^ENABLED=0" "$DEFAULT_FILE" 2>/dev/null; then
    sed -i 's/^ENABLED=0/ENABLED=1/' "$DEFAULT_FILE"
    ok "Đã sửa ENABLED=0 → ENABLED=1"
elif grep -q "^ENABLED=1" "$DEFAULT_FILE" 2>/dev/null; then
    ok "ENABLED=1 đã có — bỏ qua"
else
    echo "ENABLED=1" >> "$DEFAULT_FILE"
    ok "Đã thêm ENABLED=1"
fi

# Trỏ FILES đến đúng file conf của chúng ta
if grep -q "^FILES=" "$DEFAULT_FILE" 2>/dev/null; then
    sed -i "s|^FILES=.*|FILES=\"${CONF_FILE}\"|" "$DEFAULT_FILE"
else
    echo "FILES=\"${CONF_FILE}\"" >> "$DEFAULT_FILE"
fi
ok "FILES → $CONF_FILE"

# --------------------------------------------------------------------------- #
# BƯỚC 7: Append rule TLS vào rsyslog — idempotent
#
# TẠI SAO Rsyslog gửi đến localhost:5140 thay vì thẳng lên server:514?
# → Rsyslog chỉ gửi plaintext → Stunnel nhận tại localhost:5140
# → Stunnel mã hóa → gửi TLS đến server:6514
# → Server Stunnel giải mã → chuyển vào Rsyslog server:514
# → Rsyslog không biết gì về TLS → cấu hình đơn giản hơn
# --------------------------------------------------------------------------- #
info "Bước 7: Thêm rule TLS vào rsyslog..."

RSYSLOG_CONF="/etc/rsyslog.d/99-remote.conf"
TLS_MARKER="# TLS-VIA-STUNNEL-V3"

if [[ ! -f "$RSYSLOG_CONF" ]]; then
    warn "$RSYSLOG_CONF không tồn tại — chạy setup_client.sh trước"
else
    if grep -q "$TLS_MARKER" "$RSYSLOG_CONF"; then
        ok "Rule TLS đã có — bỏ qua (idempotent)"
    else
        cat >> "$RSYSLOG_CONF" <<RSYSLOG_RULE

# =============================================================================
${TLS_MARKER} — Thêm bởi setup_tls_client.sh v3
# Rsyslog → localhost:${STUNNEL_LOCAL_PORT} (plaintext) → Stunnel → Server:${SERVER_TLS_PORT} (TLS)
# =============================================================================
*.*     action(type="omfwd"
              target="127.0.0.1"
              port="${STUNNEL_LOCAL_PORT}"
              protocol="tcp"
              queue.type="LinkedList"
              queue.filename="fwdRule_tls_v3"
              queue.maxdiskspace="50m"
              queue.saveonshutdown="on"
              action.resumeRetryCount="-1"
              action.resumeInterval="10")
RSYSLOG_RULE
        ok "Rule TLS đã append vào $RSYSLOG_CONF"
    fi
fi

# --------------------------------------------------------------------------- #
# BƯỚC 8: Stop → Start stunnel4 (không dùng restart để tránh leftover process)
#
# TẠI SAO stop trước rồi mới start?
# → restart có thể fail nếu service ở trạng thái failed/broken
# → stop || true: bỏ qua lỗi nếu chưa chạy → start luôn từ trạng thái sạch
# --------------------------------------------------------------------------- #
info "Bước 8: Khởi động stunnel4..."

systemctl enable stunnel4 2>/dev/null || true
systemctl stop stunnel4 2>/dev/null || true   # Dừng nếu đang chạy, bỏ qua nếu chưa
sleep 1
systemctl start stunnel4
sleep 2

if systemctl is-active --quiet stunnel4; then
    ok "stunnel4 đang ACTIVE"
else
    echo ""
    echo -e "${RED}❌ stunnel4 không start — log chi tiết:${NC}"
    journalctl -u stunnel4 -n 30 --no-pager 2>/dev/null || true
    echo ""
    echo -e "${YELLOW}Kiểm tra thường gặp:${NC}"
    echo -e "  cat $CONF_FILE"
    echo -e "  ls -la $CERT_DIR/"
    exit 1
fi

# --------------------------------------------------------------------------- #
# BƯỚC 9: Kiểm tra port 5140 đang lắng nghe
# --------------------------------------------------------------------------- #
info "Bước 9: Kiểm tra port $STUNNEL_LOCAL_PORT..."

sleep 1  # Cho stunnel thêm 1s để bind port
if ss -tlnp 2>/dev/null | grep -q ":${STUNNEL_LOCAL_PORT}"; then
    ok "Port ${STUNNEL_LOCAL_PORT} đang lắng nghe — Stunnel sẵn sàng nhận từ Rsyslog"
else
    warn "Port ${STUNNEL_LOCAL_PORT} chưa thấy — kiểm tra log stunnel:"
    warn "  journalctl -u stunnel4 -n 20"
fi

# --------------------------------------------------------------------------- #
# BƯỚC 10: Test TLS handshake đến server
#
# TẠI SAO test openssl s_client ở đây?
# → Đây là bước quan trọng nhất: xác nhận cert client được server chấp nhận
# → Verify return code: 0 = cert hợp lệ, TLS handshake thành công
# → Nếu fail ở đây → Rsyslog sẽ không gửi được dù stunnel đang chạy
# --------------------------------------------------------------------------- #
info "Bước 10: Test TLS handshake đến server..."

TLS_RESULT=$(timeout 5 openssl s_client \
    -connect "${SERVER_IP}:${SERVER_TLS_PORT}" \
    -CAfile "$CA_CRT" \
    -cert "$CLIENT_CRT" \
    -key "$CLIENT_KEY" \
    </dev/null 2>&1 || true)

VERIFY_LINE=$(echo "$TLS_RESULT" | grep "Verify return code" | head -1)

if echo "$VERIFY_LINE" | grep -q "return code: 0"; then
    ok "TLS handshake THÀNH CÔNG: $VERIFY_LINE"
    CIPHER=$(echo "$TLS_RESULT" | grep "^    Cipher" | head -1 | awk '{print $NF}')
    [[ -n "$CIPHER" ]] && ok "Cipher suite: $CIPHER"
else
    echo -e "${RED}❌ TLS handshake THẤT BẠI${NC}"
    echo -e "  Verify line: ${VERIFY_LINE:-'(không đọc được)'}"
    echo ""
    echo -e "${YELLOW}Raw output (20 dòng đầu):${NC}"
    echo "$TLS_RESULT" | head -20
    echo ""
    echo -e "${YELLOW}Kiểm tra:${NC}"
    echo -e "  1. Server stunnel đang chạy? ssh ${SERVER_IP} 'systemctl status stunnel4'"
    echo -e "  2. Port 6514 mở? ssh ${SERVER_IP} 'ss -tlnp | grep 6514'"
    echo -e "  3. Cert còn hạn? openssl x509 -in $CLIENT_CRT -noout -dates"
    warn "Stunnel đang chạy nhưng TLS đến server thất bại — log sẽ không gửi được qua TLS"
fi

# --------------------------------------------------------------------------- #
# BƯỚC 11: Restart rsyslog để áp dụng rule TLS mới
# --------------------------------------------------------------------------- #
info "Bước 11: Restart rsyslog..."
systemctl restart rsyslog
sleep 1
ok "Rsyslog đã restart với rule TLS"

# --------------------------------------------------------------------------- #
# BƯỚC 12: Gửi log test và hướng dẫn verify
# --------------------------------------------------------------------------- #
info "Bước 12: Gửi log test..."
UNIQUE_TAG="TLS-SETUP-V3-$(date +%s)"
logger -p user.info -t "tls-setup" "$UNIQUE_TAG từ $CLIENT_HOSTNAME"
ok "Log test đã gửi (tag: $UNIQUE_TAG)"

# --------------------------------------------------------------------------- #
# KẾT QUẢ
# --------------------------------------------------------------------------- #
echo ""
echo -e "${GREEN}${BOLD}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   TLS CLIENT SETUP HOÀN TẤT v3 — ${CLIENT_HOSTNAME}$(printf '%*s' $((23 - ${#CLIENT_HOSTNAME})) '')║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  Client cert : $CLIENT_CRT"
echo -e "  Conf file   : $CONF_FILE"
echo -e "  Luồng       : Rsyslog → :${STUNNEL_LOCAL_PORT} → Stunnel → ${SERVER_IP}:${SERVER_TLS_PORT} (TLS)"
echo ""
echo -e "${CYAN}  Verify trên SERVER:${NC}"
echo -e "  grep '$UNIQUE_TAG' /var/log/remote/${CLIENT_HOSTNAME}/syslog.log"
echo -e "  sudo bash tls/verify_tls.sh"
echo ""
echo -e "${CYAN}  Demo tcpdump (mở 2 terminal):${NC}"
echo -e "  Terminal 1: sudo tcpdump -i any port ${SERVER_TLS_PORT} -A -c 10"
echo -e "  Terminal 2: logger -p user.info 'TLS demo cho giang vien'"
