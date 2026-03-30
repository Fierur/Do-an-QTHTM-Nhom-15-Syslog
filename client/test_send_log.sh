#!/usr/bin/env bash
# =============================================================================
# FILE    : client/test_send_log.sh
# MỤC ĐÍCH: Gửi log test đến Syslog Server để kiểm tra hệ thống hoạt động
# CÁCH CHẠY: bash test_send_log.sh  (chạy trên client, không cần root)
# KẾT QUẢ : Log sẽ xuất hiện tại /var/log/remote/<hostname>/ trên server
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# Màu sắc terminal
# --------------------------------------------------------------------------- #
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Thông tin máy
MY_HOST=$(hostname)
MY_IP=$(hostname -I | awk '{print $1}')
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}  TEST GỬI LOG — NHÓM 15 CENTRALIZED LOGGING${NC}"
echo -e "${CYAN}============================================================${NC}"
echo -e "  Hostname  : $MY_HOST"
echo -e "  IP        : $MY_IP"
echo -e "  Thời gian : $TIMESTAMP"
echo -e "  Server    : 192.168.10.100:514"
echo -e "${CYAN}============================================================${NC}"
echo ""

###############################################################################
# NHÓM 1: 5 LOG MỨC INFO (user.info)
# INFO = thông tin hoạt động bình thường của hệ thống
###############################################################################
echo -e "${GREEN}[NHÓM 1] Gửi 5 log mức INFO...${NC}"

for i in 1 2 3 4 5; do
    MSG="[INFO-$i] Dịch vụ web đang chạy bình thường trên $MY_HOST — $(date '+%T')"
    echo -e "  ${GREEN}→ Gửi INFO #$i:${NC} $MSG"
    logger -p user.info -t "test-nhom15" "$MSG"
done

echo -e "${GREEN}✅ Đã gửi 5 log INFO${NC}"
sleep 1

###############################################################################
# NHÓM 2: 3 LOG MỨC WARNING (user.warning)
# WARNING = cảnh báo, chưa lỗi nhưng cần chú ý
###############################################################################
echo ""
echo -e "${YELLOW}[NHÓM 2] Gửi 3 log mức WARNING...${NC}"

WARNINGS=(
    "Sử dụng CPU vượt 80% trong 5 phút qua"
    "Bộ nhớ RAM chỉ còn 15% trống"
    "Kết nối database chậm: response time > 500ms"
)

for i in "${!WARNINGS[@]}"; do
    MSG="[WARNING-$((i+1))] ${WARNINGS[$i]} — host=$MY_HOST"
    echo -e "  ${YELLOW}→ Gửi WARNING #$((i+1)):${NC} $MSG"
    logger -p user.warning -t "test-nhom15" "$MSG"
done

echo -e "${YELLOW}✅ Đã gửi 3 log WARNING${NC}"
sleep 1

###############################################################################
# NHÓM 3: 3 LOG MỨC ERROR (user.err)
# ERROR = lỗi xảy ra, cần điều tra
###############################################################################
echo ""
echo -e "${RED}[NHÓM 3] Gửi 3 log mức ERROR...${NC}"

ERRORS=(
    "Không thể kết nối đến database: Connection refused"
    "File cấu hình không tìm thấy: /etc/app/config.json"
    "Timeout khi gọi API bên ngoài sau 30 giây"
)

for i in "${!ERRORS[@]}"; do
    MSG="[ERROR-$((i+1))] ${ERRORS[$i]} — host=$MY_HOST"
    echo -e "  ${RED}→ Gửi ERROR #$((i+1)):${NC} $MSG"
    logger -p user.err -t "test-nhom15" "$MSG"
done

echo -e "${RED}✅ Đã gửi 3 log ERROR${NC}"
sleep 1

###############################################################################
# NHÓM 4: GIẢ LẬP BRUTE-FORCE SSH (6 lần Failed password)
# Đây là log điển hình mà Syslog Server sẽ bắt vào brute_force.log
# Message phải chứa "Failed password" để trigger alert rule
###############################################################################
echo ""
echo -e "${MAGENTA}[NHÓM 4] Giả lập tấn công brute-force SSH (6 lần)...${NC}"

FAKE_ATTACKER_IP="192.168.10.50"

for attempt in $(seq 1 6); do
    MSG="Failed password for root from $FAKE_ATTACKER_IP port $((49000 + attempt)) ssh2"
    echo -e "  ${MAGENTA}→ Brute-force attempt #$attempt:${NC} $MSG"
    logger -p auth.warning -t "sshd" "$MSG"
    # Ngủ 0.5s giữa các lần để giống thực tế hơn
    sleep 0.5
done

echo -e "${MAGENTA}✅ Đã giả lập 6 lần brute-force — kiểm tra /var/log/alerts/brute_force.log trên server${NC}"
sleep 1

###############################################################################
# NHÓM 5: 1 LOG MỨC CRITICAL (user.crit)
# CRITICAL = lỗi nghiêm trọng, cần xử lý ngay
###############################################################################
echo ""
echo -e "${RED}[NHÓM 5] Gửi 1 log mức CRITICAL...${NC}"

CRITICAL_MSG="CRITICAL: Disk full on $(hostname) — /dev/sda1 đã đầy 100%, dịch vụ có thể bị gián đoạn"
echo -e "  ${RED}→ Gửi CRITICAL:${NC} $CRITICAL_MSG"
logger -p user.crit -t "disk-monitor" "$CRITICAL_MSG"

echo -e "${RED}✅ Đã gửi 1 log CRITICAL — kiểm tra /var/log/alerts/critical.log trên server${NC}"
sleep 1

###############################################################################
# TỔNG KẾT
###############################################################################
echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}  ĐÃ HOÀN THÀNH GỬI LOG TEST${NC}"
echo -e "${CYAN}============================================================${NC}"
echo -e "  Tổng log đã gửi:"
echo -e "  • INFO    : 5 log"
echo -e "  • WARNING : 3 log"
echo -e "  • ERROR   : 3 log"
echo -e "  • AUTH    : 6 log (brute-force)"
echo -e "  • CRITICAL: 1 log"
echo -e "  Tổng cộng: 18 log"
echo ""
echo -e "  Kiểm tra trên SERVER (192.168.10.100):"
echo -e "  ${YELLOW}tail -f /var/log/remote/$MY_HOST/syslog.log${NC}"
echo -e "  ${YELLOW}cat /var/log/alerts/brute_force.log${NC}"
echo -e "  ${YELLOW}cat /var/log/alerts/critical.log${NC}"
echo -e "${CYAN}============================================================${NC}"
