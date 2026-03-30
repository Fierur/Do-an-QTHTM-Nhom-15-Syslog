#!/usr/bin/env bash
# =============================================================================
# FILE    : server/verify_logs.sh
# MỤC ĐÍCH: Kiểm tra và hiển thị trạng thái log tập trung trên Syslog Server
# CÁCH CHẠY: bash verify_logs.sh  (trên Syslog Server 192.168.10.100)
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# Màu sắc ANSI
# --------------------------------------------------------------------------- #
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# Đường dẫn thư mục log
LOG_DIR="/var/log/remote"
ALERT_DIR="/var/log/alerts"

# --------------------------------------------------------------------------- #
# Header
# --------------------------------------------------------------------------- #
clear
echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     CENTRALIZED LOGGING — VERIFY LOGS — NHÓM 15            ║"
echo "║     Syslog Server: 192.168.10.100                           ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  Thời gian kiểm tra: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

###############################################################################
# BƯỚC 1: Kiểm tra thư mục /var/log/remote/ tồn tại
###############################################################################
echo -e "${BOLD}${BLUE}[1] KIỂM TRA THƯ MỤC LOG${NC}"
echo -e "    ─────────────────────────────────────"

if [[ -d "$LOG_DIR" ]]; then
    echo -e "    ${GREEN}✅ $LOG_DIR tồn tại${NC}"
    DIRSIZE=$(du -sh "$LOG_DIR" 2>/dev/null | cut -f1)
    echo -e "       Dung lượng: ${YELLOW}$DIRSIZE${NC}"
else
    echo -e "    ${RED}❌ $LOG_DIR KHÔNG tồn tại!${NC}"
    echo -e "    Chạy setup_server.sh để khởi tạo hệ thống"
    exit 1
fi

if [[ -d "$ALERT_DIR" ]]; then
    echo -e "    ${GREEN}✅ $ALERT_DIR tồn tại${NC}"
    ALERTSIZE=$(du -sh "$ALERT_DIR" 2>/dev/null | cut -f1)
    echo -e "       Dung lượng: ${YELLOW}$ALERTSIZE${NC}"
else
    echo -e "    ${YELLOW}⚠️  $ALERT_DIR chưa tồn tại${NC}"
fi
echo ""

###############################################################################
# BƯỚC 2: Liệt kê các host đã gửi log về
###############################################################################
echo -e "${BOLD}${BLUE}[2] DANH SÁCH HOST ĐÃ GỬI LOG${NC}"
echo -e "    ─────────────────────────────────────"

# Lấy danh sách tên thư mục con trong /var/log/remote/ = các hostname
HOSTS=()
if [[ -d "$LOG_DIR" ]]; then
    while IFS= read -r -d '' dir; do
        HOSTS+=("$(basename "$dir")")
    done < <(find "$LOG_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
fi

if [[ ${#HOSTS[@]} -eq 0 ]]; then
    echo -e "    ${YELLOW}⚠️  Chưa có host nào gửi log về${NC}"
    echo -e "    Hãy chạy test_send_log.sh trên các client"
else
    echo -e "    Tìm thấy ${GREEN}${#HOSTS[@]} host${NC}:"
    for host in "${HOSTS[@]}"; do
        echo -e "      ${CYAN}• $host${NC}"
    done
fi
echo ""

###############################################################################
# BƯỚC 3: Chi tiết log từng host
###############################################################################
echo -e "${BOLD}${BLUE}[3] CHI TIẾT LOG TỪNG HOST${NC}"
echo -e "    ─────────────────────────────────────"

for host in "${HOSTS[@]}"; do
    HOST_DIR="$LOG_DIR/$host"
    echo ""
    echo -e "    ${MAGENTA}${BOLD}▶ HOST: $host${NC}"
    echo -e "    ${MAGENTA}  Thư mục: $HOST_DIR${NC}"
    echo -e "    ┌──────────────────────────────────────────"

    # Duyệt qua từng file log của host
    for logfile in syslog.log auth.log error.log; do
        FILEPATH="$HOST_DIR/$logfile"
        if [[ -f "$FILEPATH" ]]; then
            LINECOUNT=$(wc -l < "$FILEPATH" 2>/dev/null || echo 0)
            FILESIZE=$(du -sh "$FILEPATH" 2>/dev/null | cut -f1)
            LASTMOD=$(stat -c '%y' "$FILEPATH" 2>/dev/null | cut -d. -f1)
            echo -e "    │  ${GREEN}✅ $logfile${NC}"
            echo -e "    │     Số dòng   : ${YELLOW}$LINECOUNT${NC}"
            echo -e "    │     Dung lượng: ${YELLOW}$FILESIZE${NC}"
            echo -e "    │     Cập nhật  : $LASTMOD"
        else
            echo -e "    │  ${RED}❌ $logfile — chưa có${NC}"
        fi
    done
    echo -e "    └──────────────────────────────────────────"

    # Hiển thị 10 dòng log mới nhất từ syslog.log
    SYSLOG="$HOST_DIR/syslog.log"
    if [[ -f "$SYSLOG" && -s "$SYSLOG" ]]; then
        echo -e ""
        echo -e "    ${CYAN}10 dòng mới nhất từ $host/syslog.log:${NC}"
        echo -e "    ┌────────────────────────────────────────────────────────────"
        tail -10 "$SYSLOG" | while IFS= read -r line; do
            echo -e "    │ $line"
        done
        echo -e "    └────────────────────────────────────────────────────────────"
    fi
done

echo ""

###############################################################################
# BƯỚC 4: Kiểm tra file alert
###############################################################################
echo -e "${BOLD}${BLUE}[4] KIỂM TRA FILE CẢNH BÁO (ALERTS)${NC}"
echo -e "    ─────────────────────────────────────"

ALERT_FILES=("brute_force.log" "critical.log")

for alertfile in "${ALERT_FILES[@]}"; do
    FILEPATH="$ALERT_DIR/$alertfile"
    if [[ -f "$FILEPATH" ]]; then
        LINECOUNT=$(wc -l < "$FILEPATH" 2>/dev/null || echo 0)
        if [[ $LINECOUNT -gt 0 ]]; then
            echo -e "    ${RED}🚨 $alertfile — $LINECOUNT sự kiện cảnh báo!${NC}"
            echo -e "    ${YELLOW}   5 cảnh báo mới nhất:${NC}"
            tail -5 "$FILEPATH" | while IFS= read -r line; do
                echo -e "       ${RED}│${NC} $line"
            done
        else
            echo -e "    ${GREEN}✅ $alertfile — trống (chưa có cảnh báo)${NC}"
        fi
    else
        echo -e "    ${YELLOW}⚠️  $alertfile — file chưa được tạo${NC}"
    fi
    echo ""
done

###############################################################################
# BƯỚC 5: Kiểm tra trạng thái dịch vụ Rsyslog
###############################################################################
echo -e "${BOLD}${BLUE}[5] TRẠNG THÁI DỊCH VỤ RSYSLOG${NC}"
echo -e "    ─────────────────────────────────────"

if systemctl is-active --quiet rsyslog; then
    UPTIME=$(systemctl show rsyslog --property=ActiveEnterTimestamp --value 2>/dev/null || echo "N/A")
    echo -e "    ${GREEN}✅ rsyslog đang chạy (ACTIVE)${NC}"
    echo -e "       Khởi động từ: $UPTIME"
else
    echo -e "    ${RED}❌ rsyslog KHÔNG chạy!${NC}"
    echo -e "    Chạy: sudo systemctl restart rsyslog"
fi

# Kiểm tra port đang lắng nghe
echo ""
echo -e "    Port đang lắng nghe:"
if ss -ulnp 2>/dev/null | grep -q ":514"; then
    echo -e "    ${GREEN}✅ UDP/514 đang lắng nghe${NC}"
else
    echo -e "    ${RED}❌ UDP/514 chưa mở${NC}"
fi
if ss -tlnp 2>/dev/null | grep -q ":514"; then
    echo -e "    ${GREEN}✅ TCP/514 đang lắng nghe${NC}"
else
    echo -e "    ${RED}❌ TCP/514 chưa mở${NC}"
fi

###############################################################################
# TỔNG KẾT
###############################################################################
echo ""
echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                     KIỂM TRA HOÀN TẤT                      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  Các lệnh hữu ích:"
echo -e "  ${YELLOW}tail -f /var/log/remote/*/syslog.log${NC}  — theo dõi log realtime"
echo -e "  ${YELLOW}tail -f /var/log/alerts/*.log${NC}          — theo dõi cảnh báo"
echo -e "  ${YELLOW}bash tools/search_log.sh all 'Failed' $(date +%Y-%m-%d)${NC}"
