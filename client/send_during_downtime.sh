#!/usr/bin/env bash
# =============================================================================
# FILE    : client/send_during_downtime.sh
# MỤC ĐÍCH: Gửi log trong lúc Syslog Server đang offline để chứng minh
#           Disk Queue lưu log cục bộ và gửi lại khi server online
# CÁCH CHẠY: bash send_during_downtime.sh  (chạy trên CLIENT khi server down)
# THỜI ĐIỂM: Chạy trong lúc simulate_server_down.sh đang đếm ngược (Bước 3)
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# Màu terminal
# --------------------------------------------------------------------------- #
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

MY_HOST=$(hostname)
TOTAL_MESSAGES=400
SERVER_IP="192.168.10.100"

# Đường dẫn queue trên disk (phải khớp với queue.filename trong rsyslog-client.conf)
# TẠI SAO đường dẫn này?
# → Trong rsyslog-client.conf có: $WorkDirectory /var/spool/rsyslog
#   và queue.filename="fwdRule_auth" → Rsyslog ghép thành:
#   /var/spool/rsyslog/fwdRule_auth-<số>.qf  (file dữ liệu)
#   /var/spool/rsyslog/fwdRule_auth.qi        (file index/metadata)
# Kiểm tra file này để xác nhận queue thực sự lưu xuống đĩa
QUEUE_DIR="/var/spool/rsyslog"

echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║    SEND DURING DOWNTIME — Kiểm tra Disk Queue              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  Host   : $MY_HOST"
echo -e "  Server : $SERVER_IP (hiện đang OFFLINE)"
echo -e "  Sẽ gửi : $TOTAL_MESSAGES dòng log"
echo ""

# Cảnh báo: server có thể đã online lại
echo -e "${YELLOW}  Script này phải chạy TRONG KHI server đang offline!${NC}"
echo -e "${YELLOW}   Nếu server online rồi, log sẽ gửi thẳng (không qua queue)${NC}"
echo ""

# Kiểm tra nhanh server còn offline không (timeout 2 giây)
echo " Đang chờ server OFFLINE để test Disk Queue..."

while nc -zw2 "$SERVER_IP" 514 2>/dev/null; do
    echo " Server vẫn ONLINE... chờ tiếp"
    sleep 2
done

echo -e "${GREEN} Server đã OFFLINE — bắt đầu test${NC}"
echo ""
echo -e "${GREEN} Bắt đầu gửi $TOTAL_MESSAGES log (server đang down)...${NC}"

# --------------------------------------------------------------------------- #
# Gửi 50 dòng log với tag DOWNTIME_TEST
# --------------------------------------------------------------------------- #
for seq in $(seq 1 $TOTAL_MESSAGES); do
    # Format message có seq number để verify_concurrent.sh có thể kiểm tra sau
    MSG=$(printf "DOWNTIME_TEST seq=%03d host=%s ts=%s — Server đang DOWN, log vào Disk Queue" \
          "$seq" "$MY_HOST" "$(date +%s.%N)")

    # Gửi qua TCP (auth facility để kích hoạt TCP action trong rsyslog-client.conf)
    # TẠI SAO dùng auth.warning thay vì user.info?
    # → Trong rsyslog-client.conf, action TCP được bind với auth.* và *.crit
    #   Nếu dùng user.info → chỉ gửi qua UDP (không có queue) → mất ngay khi server down
    #   Dùng auth.warning → kích hoạt TCP action có Disk Queue → log được lưu lại
    logger -p auth.warning -t "downtime-test" "$MSG"

    # In ra console để thấy trực quan
    echo -e "  ${YELLOW}Gửi log #$(printf '%03d' $seq)${NC} — Server đang down, log đang vào Disk Queue..."

    # Sleep nhỏ để không gửi quá nhanh (50ms giữa các message)
    sleep 0.05
done

echo ""
echo -e "${GREEN} Đã gửi xong $TOTAL_MESSAGES dòng log${NC}"
echo ""

# --------------------------------------------------------------------------- #
# Kiểm tra Disk Queue đã được tạo chưa
#
# TẠI SAO file .qf và .qi xuất hiện?
# → Khi TCP connection đến server thất bại, Rsyslog chuyển sang chế độ
#   "disk queue": mỗi message được serialize và ghi vào file .qf
#   File .qi là index file, lưu vị trí đọc/ghi hiện tại
#   → Sau khi server online, Rsyslog đọc từ vị trí trong .qi và gửi từng message
#   → Khi queue rỗng, file .qf và .qi được xóa tự động
# --------------------------------------------------------------------------- #
echo -e "${BOLD}${CYAN}[KIỂM TRA] Disk Queue trên đĩa:${NC}"
echo -e "  Thư mục queue: $QUEUE_DIR"
echo ""

if [[ -d "$QUEUE_DIR" ]]; then
    shopt -s nullglob

    # Bắt tất cả file queue: dạng số (.00000001) + prefix nếu có
    queue_files=(
        "$QUEUE_DIR"/*.[0-9]*
        "$QUEUE_DIR"/fwdRule_auth*
        "$QUEUE_DIR"/*.qf
        "$QUEUE_DIR"/*.qi
    )

    if (( ${#queue_files[@]} > 0 )); then
        echo -e "  ${GREEN}✅ Queue files đã được tạo (log đang chờ trên disk):${NC}"
        
        for f in "${queue_files[@]}"; do
            [[ -e "$f" ]] || continue
            echo -e "    ${GREEN}$(ls -lh "$f")${NC}"
        done

        echo ""
        echo -e "  ${CYAN}Giải thích file:${NC}"
        echo -e "  • *.00000001 → File queue (log đang chờ gửi)"
        echo -e "  • *.qf / *.qi → Queue format cũ (nếu có)"
        echo -e "  • *.state → Trạng thái queue"
        echo -e "  • Server online → rsyslog đọc và gửi dần"
        echo -e "  • Queue rỗng → file tự xóa"

    else
        echo -e "  ${YELLOW}⚠️ Không thấy file queue${NC}"
        echo -e "  Có thể vì:"
        echo -e "  1. Queue đang ở memory (chưa flush xuống disk)"
        echo -e "  2. Server đã online → queue flush rất nhanh"
        echo -e "  3. Sai WorkDirectory hoặc queue.filename"
    fi

    echo ""
    echo -e "  ${BOLD}Tất cả file trong $QUEUE_DIR:${NC}"
    ls -lah "$QUEUE_DIR" 2>/dev/null || echo "  (trống)"

else
    echo -e "  ${RED}❌ Thư mục $QUEUE_DIR không tồn tại!${NC}"
    echo -e "  Kiểm tra:"
    echo -e "  • \$WorkDirectory trong rsyslog.conf"
    echo -e "  • queue.filename trong action"
    echo -e "  • Tạo thủ công nếu cần:"
    echo -e "    sudo mkdir -p $QUEUE_DIR && sudo chown syslog: $QUEUE_DIR"
fi

echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}  TIẾP THEO: Quay lại terminal SERVER${NC}"
echo -e "${CYAN}  Server sẽ tự động restart và flush queue trong 15 giây${NC}"
echo -e "${CYAN}  Sau đó chạy: bash server/verify_logs.sh để xác nhận${NC}"
echo -e "${CYAN}============================================================${NC}"
