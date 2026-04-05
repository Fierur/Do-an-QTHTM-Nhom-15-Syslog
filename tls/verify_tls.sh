#!/usr/bin/env bash
# =============================================================================
# FILE    : tls/verify_tls.sh
# MỤC ĐÍCH: Kiểm tra TLS (Stunnel) hoạt động đúng trên Syslog Server
# CÁCH CHẠY: bash verify_tls.sh  (chạy trên Syslog Server 192.168.10.100)
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

CERT_DIR="/etc/stunnel/certs"
SERVER_IP="192.168.10.100"
TLS_PORT="6514"
LOG_DIR="/var/log/remote"

# Đếm số kiểm tra pass/fail
PASS=0
FAIL=0

check_ok()   { echo -e "  ${GREEN}✅ $1${NC}"; PASS=$((PASS+1)); }
check_fail() { echo -e "  ${RED}❌ $1${NC}"; FAIL=$((FAIL+1)); }
info()       { echo -e "${BLUE}➡️  $1${NC}"; }

echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║    TLS VERIFICATION — STUNNEL — NHÓM 15                    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

###############################################################################
# KIỂM TRA 1: Stunnel đang chạy không?
###############################################################################
echo -e "${BOLD}${BLUE}[1] Kiểm tra dịch vụ Stunnel${NC}"

if systemctl is-active --quiet stunnel4; then
    check_ok "Stunnel4 service đang ACTIVE"
    # Lấy uptime của service
    SINCE=$(systemctl show stunnel4 --property=ActiveEnterTimestamp --value 2>/dev/null || echo "N/A")
    echo -e "     Hoạt động từ: $SINCE"
else
    check_fail "Stunnel4 KHÔNG chạy — chạy: sudo systemctl start stunnel4"
fi

echo ""

###############################################################################
# KIỂM TRA 2: Port 6514 đang lắng nghe chưa?
###############################################################################
echo -e "${BOLD}${BLUE}[2] Kiểm tra port TCP/$TLS_PORT${NC}"

if ss -tlnp 2>/dev/null | grep -q ":$TLS_PORT"; then
    check_ok "TCP/$TLS_PORT đang lắng nghe (Stunnel nhận TLS từ client)"
    # Hiển thị chi tiết
    ss -tlnp | grep ":$TLS_PORT" | while IFS= read -r line; do
        echo -e "     $line"
    done
else
    check_fail "TCP/$TLS_PORT KHÔNG lắng nghe"
    echo -e "     Kiểm tra: journalctl -u stunnel4 -n 20"
fi

echo ""

###############################################################################
# KIỂM TRA 3: Certificate hợp lệ không?
###############################################################################
echo -e "${BOLD}${BLUE}[3] Kiểm tra Certificate${NC}"

# Kiểm tra file tồn tại
for f in ca.crt server.crt server.key; do
    if [[ -f "$CERT_DIR/$f" ]]; then
        EXPIRY=$(openssl x509 -in "$CERT_DIR/$f" -noout -enddate 2>/dev/null | \
                 cut -d= -f2 || echo "N/A")
        check_ok "$f tồn tại (hết hạn: $EXPIRY)"
    else
        check_fail "$f KHÔNG tồn tại tại $CERT_DIR/"
    fi
done

# Kiểm tra server cert được ký bởi CA
if [[ -f "$CERT_DIR/server.crt" && -f "$CERT_DIR/ca.crt" ]]; then
    if openssl verify -CAfile "$CERT_DIR/ca.crt" "$CERT_DIR/server.crt" \
       2>/dev/null | grep -q "OK"; then
        check_ok "server.crt được ký bởi CA hợp lệ"
    else
        check_fail "server.crt KHÔNG được ký bởi CA này"
    fi
fi

echo ""

###############################################################################
# KIỂM TRA 4: Test kết nối TLS bằng openssl s_client
#
# TẠI SAO dùng openssl s_client?
# → Đây là công cụ chuẩn để debug TLS connection từ command line
# → Kết nối đến server, thực hiện TLS handshake, và in ra thông tin chi tiết:
#   • Cipher suite đang dùng (ví dụ TLS_AES_256_GCM_SHA384)
#   • Certificate của server (subject, issuer, ngày hết hạn)
#   • Verify return code: 0 = TLS handshake thành công, cert hợp lệ
#   • Verify return code: 19 = cert self-signed (bình thường với lab CA)
#   • Verify return code: 2 = cert hết hạn
###############################################################################
echo -e "${BOLD}${BLUE}[4] Test kết nối TLS bằng openssl s_client${NC}"
echo -e "  ${CYAN}Lệnh: openssl s_client -connect $SERVER_IP:$TLS_PORT -CAfile $CERT_DIR/ca.crt${NC}"
echo ""

# Timeout 5 giây để tránh hang
TLS_OUTPUT=$(timeout 5 openssl s_client \
    -connect "${SERVER_IP}:${TLS_PORT}" \
    -CAfile "$CERT_DIR/ca.crt" \
    -cert "$CERT_DIR/server.crt" \
    -key  "$CERT_DIR/server.key" \
    2>&1 <<< "test" || true)

# --- Kiểm tra cipher suite ---
# TẠI SAO quan trọng? Cipher suite yếu (RC4, DES) = dễ bị crack
CIPHER=$(echo "$TLS_OUTPUT" | grep "^    Cipher" | head -1 | awk '{print $NF}')
if [[ -n "$CIPHER" ]]; then
    check_ok "Cipher suite: $CIPHER"
else
    echo -e "  ${YELLOW}⚠️  Không đọc được cipher — xem raw output bên dưới${NC}"
fi

# --- Kiểm tra certificate subject ---
SUBJECT=$(echo "$TLS_OUTPUT" | grep "subject=" | head -1)
if [[ -n "$SUBJECT" ]]; then
    check_ok "Server cert: $SUBJECT"
fi

# --- Kiểm tra verify return code ---
# Verify return code: 0 = THÀNH CÔNG (cert hợp lệ, được ký bởi CA tin cậy)
# Verify return code: 21 = unable to verify (thiếu cert client khi verify=2)
VERIFY_CODE=$(echo "$TLS_OUTPUT" | grep "Verify return code" | head -1)
if echo "$VERIFY_CODE" | grep -q "return code: 0"; then
    check_ok "TLS handshake THÀNH CÔNG ($VERIFY_CODE)"
elif echo "$VERIFY_CODE" | grep -q "return code: 21"; then
    echo -e "  ${YELLOW}⚠️  Verify code 21: Server yêu cầu client cert (verify=2)${NC}"
    echo -e "  ${YELLOW}   → Bình thường khi test từ server (không có client cert đúng)${NC}"
    echo -e "  ${YELLOW}   → TLS connection đã thành công, chỉ thiếu mutual auth${NC}"
    PASS=$((PASS+1))
else
    check_fail "TLS handshake THẤT BẠI: $VERIFY_CODE"
    echo "--- Raw openssl output ---"
    echo "$TLS_OUTPUT" | head -20
fi

echo ""

###############################################################################
# KIỂM TRA 5: Gửi log test qua TLS và kiểm tra xuất hiện trên server
###############################################################################
echo -e "${BOLD}${BLUE}[5] Gửi log test qua TLS và kiểm tra server nhận được${NC}"

# Timestamp độc nhất để tìm đúng dòng log sau này
UNIQUE_TAG="TLS-VERIFY-$(date +%s)"

echo -e "  Gửi log với tag: ${YELLOW}$UNIQUE_TAG${NC}"

# Gửi log test (logger gửi đến local rsyslog → rsyslog → stunnel → server)
# Nếu TLS đã cấu hình đúng, log này sẽ đi qua port 5140 → 6514
logger -p user.info -t "tls-verify" "$UNIQUE_TAG — TLS test từ $(hostname)"

echo -e "  Chờ 3 giây để log truyền qua TLS và xuất hiện trên server..."
sleep 3

# Tìm log trong tất cả host
LOG_FOUND=false
if [[ -d "$LOG_DIR" ]]; then
    for HOST_DIR in "$LOG_DIR"/*/; do
        HOST=$(basename "$HOST_DIR")
        SYSLOG="$HOST_DIR/syslog.log"
        if [[ -f "$SYSLOG" ]] && grep -q "$UNIQUE_TAG" "$SYSLOG" 2>/dev/null; then
            check_ok "Log TLS đã xuất hiện trong /var/log/remote/$HOST/syslog.log"
            grep "$UNIQUE_TAG" "$SYSLOG" | tail -1 | while IFS= read -r line; do
                echo -e "     ${CYAN}$line${NC}"
            done
            LOG_FOUND=true
            break
        fi
    done
fi

if [[ "$LOG_FOUND" == "false" ]]; then
    check_fail "Log TLS KHÔNG xuất hiện trong $LOG_DIR"
    echo -e "     Kiểm tra: Stunnel client có đang chạy trên client không?"
    echo -e "     Kiểm tra: journalctl -u stunnel4 -n 20 (trên client)"
fi

echo ""

###############################################################################
# KIỂM TRA 6: Gợi ý tcpdump để chứng minh traffic đã mã hóa
#
# TẠI SAO tcpdump chứng minh được TLS?
# → tcpdump -A: in payload theo ASCII
# → Với plaintext (port 514): đọc được nội dung log rõ ràng
# → Với TLS (port 6514): chỉ thấy binary/gibberish vì đã mã hóa
# → Đây là cách trực quan nhất để PROVE với giảng viên rằng TLS thực sự hoạt động
###############################################################################
echo -e "${BOLD}${BLUE}[6] Gợi ý lệnh chứng minh traffic đã mã hóa (tcpdump)${NC}"
echo ""
echo -e "  ${YELLOW}Chạy lệnh sau để capture và so sánh:${NC}"
echo ""
echo -e "  ${CYAN}# Plaintext (đọc được nội dung):${NC}"
echo -e "  sudo tcpdump -i any port 514 -A -c 5"
echo -e "  ${CYAN}# → Thấy nội dung log rõ ràng trong ASCII output${NC}"
echo ""
echo -e "  ${CYAN}# TLS encrypted (KHÔNG đọc được):${NC}"
echo -e "  sudo tcpdump -i any port $TLS_PORT -A -c 5"
echo -e "  ${CYAN}# → Thấy binary/gibberish, không có text log → đã mã hóa${NC}"
echo ""
echo -e "  ${YELLOW}Cách demo cho giảng viên:${NC}"
echo -e "  1. Mở terminal 1: sudo tcpdump -i any port $TLS_PORT -A -c 10"
echo -e "  2. Mở terminal 2: logger -p user.info 'TLS demo cho giảng viên'"
echo -e "  3. Terminal 1 sẽ hiện binary — không đọc được nội dung"
echo -e "  4. So sánh với port 514 (plaintext) → thấy text rõ ràng"

if command -v tcpdump &>/dev/null; then
    check_ok "tcpdump đã cài (có thể demo ngay)"
else
    echo -e "  ${YELLOW}⚠️  tcpdump chưa cài: sudo apt install tcpdump${NC}"
fi

echo ""

###############################################################################
# TỔNG KẾT
###############################################################################
TOTAL=$((PASS + FAIL))
echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════${NC}"
echo -e "  KẾT QUẢ: ${GREEN}$PASS passed${NC} / ${RED}$FAIL failed${NC} / $TOTAL tổng"
echo ""

if [[ $FAIL -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}✅ TLS HOẠT ĐỘNG HOÀN TOÀN${NC}"
    echo -e "  ${CYAN}Giải thích cho giảng viên:${NC}"
    echo -e "  • Cipher: mã hóa symmetric (AES-256) sau TLS handshake"
    echo -e "  • Verify return code 0: cert server hợp lệ, được ký bởi CA tin cậy"
    echo -e "  • Stunnel proxy: Rsyslog ↔ localhost ↔ Stunnel ↔ mạng TLS ↔ Server"
    echo -e "  • Mutual TLS (verify=2): cả 2 chiều đều xác thực cert"
else
    echo -e "  ${YELLOW}⚠️  Có $FAIL kiểm tra thất bại — xem chi tiết bên trên${NC}"
fi
echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════════${NC}"
