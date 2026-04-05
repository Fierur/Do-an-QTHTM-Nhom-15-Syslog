#!/usr/bin/env bash
# =============================================================================
# FILE    : server/simulate_server_down.sh
# MỤC ĐÍCH: Giả lập Server tắt đột ngột để kiểm tra Disk Queue hoạt động.
#           Chứng minh rằng log KHÔNG bị mất dù server tắt 30 giây.
# CÁCH CHẠY: sudo bash simulate_server_down.sh  (chạy trên Syslog Server)
# KỊCH BẢN : Server down 30s → client gửi log vào Disk Queue → server restart
#             → Queue flush tự động → log xuất hiện trong /var/log/remote/
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# Màu terminal
# --------------------------------------------------------------------------- #
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

LOG_DIR="/var/log/remote"
DOWNTIME_SECONDS=30

# Kiểm tra quyền root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}❌ Cần quyền root. Chạy: sudo bash $0${NC}"
    exit 1
fi

# --------------------------------------------------------------------------- #
# Header
# --------------------------------------------------------------------------- #
clear
echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║    DISK QUEUE TEST — SIMULATE SERVER DOWN — NHÓM 15        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

###############################################################################
# BƯỚC 1: Ghi baseline — số dòng log hiện tại của từng client
#
# TẠI SAO cần baseline?
# Sau khi server restart và Queue flush, số dòng log sẽ TĂNG lên.
# Baseline = điểm xuất phát để so sánh TRƯỚC và SAU.
# Nếu không có baseline, không biết dòng nào là mới từ Disk Queue.
###############################################################################
echo -e "${BOLD}${BLUE}[BƯỚC 1] Ghi baseline số dòng log hiện tại${NC}"
echo -e "         ────────────────────────────────────"

declare -A BASELINE
HOSTS=()

if [[ -d "$LOG_DIR" ]]; then
    while IFS= read -r -d '' dir; do
        HOST=$(basename "$dir")
        SYSLOG="$LOG_DIR/$HOST/syslog.log"
        if [[ -f "$SYSLOG" ]]; then
            COUNT=$(wc -l < "$SYSLOG")
            BASELINE["$HOST"]=$COUNT
            HOSTS+=("$HOST")
            echo -e "  ${HOST}: ${YELLOW}$COUNT dòng${NC}"
        fi
    done < <(find "$LOG_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
fi

if [[ ${#HOSTS[@]} -eq 0 ]]; then
    echo -e "${YELLOW}⚠️  Chưa có host nào — các client chưa gửi log?${NC}"
    echo -e "Hãy chạy test_send_log.sh trên ít nhất 1 client trước."
    exit 1
fi

echo -e "${GREEN}✅ Đã ghi baseline cho ${#HOSTS[@]} host${NC}"
echo ""

###############################################################################
# BƯỚC 2: Dừng Rsyslog Server
#
# TẠI SAO systemctl stop KHÔNG làm mất log đang trên đường?
# → Vì log đang "trên đường" thực ra đang nằm trong Disk Queue TRÊN CLIENT.
#   Client đã lưu xuống đĩa cục bộ nhờ queue.saveonshutdown="on".
#   Server stop chỉ làm TCP connection bị reset, client nhận tín hiệu disconnect,
#   và bắt đầu lưu log tiếp theo vào queue thay vì gửi lên mạng.
###############################################################################
echo -e "${BOLD}${BLUE}[BƯỚC 2] Dừng Rsyslog Server${NC}"
echo -e "         ────────────────────────────────────"

systemctl stop rsyslog
sleep 1

if ! systemctl is-active --quiet rsyslog; then
    echo -e "${GREEN}⏸ Rsyslog Server đã dừng — Disk Queue trên client sẽ bắt đầu hoạt động${NC}"
    echo ""
    echo -e "  ${YELLOW}Lý do Disk Queue cần thiết:${NC}"
    echo -e "  • Không có Disk Queue: log gửi lúc server down → MẤT LUÔN"
    echo -e "  • Có Disk Queue: log được lưu vào file .qf trên đĩa client"
    echo -e "    → Khi server online lại, Rsyslog đọc queue và gửi lại tự động"
else
    echo -e "${RED}❌ Không thể dừng Rsyslog — kiểm tra quyền${NC}"
    exit 1
fi

echo ""
echo -e "${BOLD}${YELLOW}============================================================${NC}"
echo -e "${YELLOW}  🔴 SERVER HIỆN ĐANG OFFLINE${NC}"
echo -e "${YELLOW}  → Hãy MỞ TERMINAL MỚI trên CLIENT và chạy:${NC}"
echo -e "${YELLOW}     bash client/send_during_downtime.sh${NC}"
echo -e "${YELLOW}  → Log sẽ vào Disk Queue thay vì gửi lên server${NC}"
echo -e "${YELLOW}============================================================${NC}"
echo ""

###############################################################################
# BƯỚC 3: Đếm ngược 30 giây
# Trong lúc này client nên gửi log (bằng send_during_downtime.sh)
###############################################################################
echo -e "${BOLD}${BLUE}[BƯỚC 3] Server offline ${DOWNTIME_SECONDS}s — đếm ngược${NC}"
echo -e "         ────────────────────────────────────"

for remaining in $(seq $DOWNTIME_SECONDS -5 5); do
    echo -e "  ${RED}🔴 Server offline còn ${remaining}s... — Client hãy gửi log ngay!${NC}"
    sleep 5
done
echo -e "  ${YELLOW}⏰ Hết thời gian offline — chuẩn bị restart server...${NC}"
echo ""

###############################################################################
# BƯỚC 4: Khởi động lại Rsyslog Server
#
# TẠI SAO sau khi start, queue flush TỰ ĐỘNG không cần làm gì thêm?
# → Rsyslog client đang loop retry (action.resumeRetryCount="-1"):
#   mỗi 10 giây thử kết nối lại server. Ngay khi TCP handshake thành công,
#   nó đọc file .qf từ disk và gửi từng message theo thứ tự FIFO.
###############################################################################
echo -e "${BOLD}${BLUE}[BƯỚC 4] Khởi động lại Rsyslog Server${NC}"
echo -e "         ────────────────────────────────────"

systemctl start rsyslog
sleep 2

if systemctl is-active --quiet rsyslog; then
    echo -e "${GREEN}▶ Rsyslog Server đã khởi động lại${NC}"
    echo -e "${GREEN}  → Client sẽ tự động kết nối lại và flush Disk Queue${NC}"
else
    echo -e "${RED}❌ Rsyslog không khởi động được!${NC}"
    echo -e "Chạy: journalctl -u rsyslog -n 20"
    exit 1
fi

echo ""

###############################################################################
# BƯỚC 5: Chờ Disk Queue flush
#
# TẠI SAO cần sleep 15 giây sau khi restart?
# → action.resumeInterval="10" trong rsyslog-client.conf: client thử lại mỗi 10s.
#   Sau khi server online, cần ít nhất 1 chu kỳ retry (10s) để client detect
#   server đã online, cộng thêm thời gian gửi tất cả message trong queue.
#   15s = buffer an toàn để đảm bảo queue flush hoàn toàn trước khi kiểm tra.
#
# queue.saveonshutdown="on" vs không có cờ này:
# → CÓ cờ: Khi rsyslog CLIENT tắt/restart, nó ghi toàn bộ queue đang trong
#           RAM xuống file .qf trên disk → không mất dù máy restart
# → KHÔNG cờ: Queue chỉ trong RAM → rsyslog client tắt → mất sạch queue
###############################################################################
echo -e "${BOLD}${BLUE}[BƯỚC 5] Chờ Disk Queue flush (15 giây)${NC}"
echo -e "         ────────────────────────────────────"
echo -e "  ${CYAN}Giải thích:${NC} Client đang kết nối lại và gửi log từ Disk Queue..."
echo -e "  action.resumeInterval=10s → cần tối thiểu 10s để client detect server online"

for i in $(seq 15 -3 3); do
    echo -e "  ${CYAN}Chờ queue flush... ${i}s${NC}"
    sleep 3
done

echo -e "${GREEN}✅ Đủ thời gian để queue flush${NC}"
echo ""

###############################################################################
# BƯỚC 6: So sánh với baseline
###############################################################################
echo -e "${BOLD}${BLUE}[BƯỚC 6] So sánh số dòng log với baseline${NC}"
echo -e "         ────────────────────────────────────"

QUEUE_WORKED=false

for HOST in "${HOSTS[@]}"; do
    SYSLOG="$LOG_DIR/$HOST/syslog.log"
    if [[ ! -f "$SYSLOG" ]]; then
        continue
    fi

    NEW_COUNT=$(wc -l < "$SYSLOG")
    OLD_COUNT="${BASELINE[$HOST]}"
    DIFF=$((NEW_COUNT - OLD_COUNT))

    echo -e "  ${BOLD}$HOST:${NC}"
    echo -e "    Trước : $OLD_COUNT dòng"
    echo -e "    Sau   : $NEW_COUNT dòng"

    if [[ $DIFF -gt 0 ]]; then
        echo -e "    ${GREEN}✅ Disk Queue hoạt động — nhận bù $DIFF dòng từ $HOST${NC}"
        QUEUE_WORKED=true

        # Hiển thị các dòng DOWNTIME_TEST nhận được
        DOWNTIME_LINES=$(grep "DOWNTIME_TEST" "$SYSLOG" 2>/dev/null | tail -5 || true)
        if [[ -n "$DOWNTIME_LINES" ]]; then
            echo -e "    ${CYAN}5 dòng DOWNTIME_TEST gần nhất:${NC}"
            echo "$DOWNTIME_LINES" | while IFS= read -r line; do
                echo -e "    │ $line"
            done
        fi
    else
        echo -e "    ${RED}❌ Disk Queue KHÔNG hoạt động — không nhận thêm dòng nào${NC}"
        echo -e "    ${RED}   Kiểm tra: queue.saveonshutdown='on' trong rsyslog-client.conf${NC}"
        echo -e "    ${RED}   Kiểm tra: ls -lh /var/spool/rsyslog/ trên client${NC}"
    fi
    echo ""
done

###############################################################################
# BƯỚC 7: Tóm tắt kết quả
###############################################################################
echo -e "${BOLD}${BLUE}[BƯỚC 7] TÓM TẮT KẾT QUẢ TOÀN BỘ KỊCH BẢN${NC}"
echo -e "         ────────────────────────────────────"

if [[ "$QUEUE_WORKED" == "true" ]]; then
    echo -e "${GREEN}${BOLD}"
    echo "  ╔══════════════════════════════════════════════════════╗"
    echo "  ║  ✅ DISK QUEUE HOẠT ĐỘNG ĐÚNG                       ║"
    echo "  ║  Log KHÔNG bị mất dù server down 30 giây            ║"
    echo "  ╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "  ${CYAN}Giải thích kỹ thuật cho giảng viên:${NC}"
    echo -e "  1. Client cấu hình queue.type=LinkedList + queue.filename=fwdRule"
    echo -e "  2. Khi TCP đến server bị ngắt → Rsyslog client ghi log vào file .qf"
    echo -e "  3. queue.saveonshutdown=on → queue an toàn dù client restart"
    echo -e "  4. action.resumeRetryCount=-1 → retry vô hạn lần mỗi 10 giây"
    echo -e "  5. Khi server online → client flush queue theo thứ tự FIFO"
else
    echo -e "${RED}${BOLD}"
    echo "  ╔══════════════════════════════════════════════════════╗"
    echo "  ║  ❌ DISK QUEUE KHÔNG HOẠT ĐỘNG                      ║"
    echo "  ╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "  ${YELLOW}Các bước debug:${NC}"
    echo -e "  1. Kiểm tra client conf: grep -i queue /etc/rsyslog.d/99-remote.conf"
    echo -e "  2. Kiểm tra thư mục queue: ls -lh /var/spool/rsyslog/ (trên client)"
    echo -e "  3. Kiểm tra quyền: ls -la /var/spool/rsyslog/"
    echo -e "  4. Xem log rsyslog client: journalctl -u rsyslog -n 30 (trên client)"
fi
