#!/usr/bin/env bash
# =============================================================================
# FILE    : tools/search_log.sh
# MỤC ĐÍCH: Tìm kiếm log theo hostname, keyword và ngày tháng
# CÁCH CHẠY: bash search_log.sh [hostname|all] [keyword] [YYYY-MM-DD]
# VÍ DỤ   :
#   bash search_log.sh all "Failed password"          — tìm brute-force tất cả host
#   bash search_log.sh web-client "error" 2024-01-15  — tìm lỗi ngày cụ thể
#   bash search_log.sh all "CRITICAL"                 — tìm CRITICAL tất cả host
#   bash search_log.sh db-client "timeout"            — tìm timeout trên db-client
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
BOLD='\033[1m'
NC='\033[0m'

LOG_DIR="/var/log/remote"

# --------------------------------------------------------------------------- #
# Hàm hiển thị hướng dẫn sử dụng
# --------------------------------------------------------------------------- #
usage() {
    echo -e "${BOLD}Cú pháp:${NC}"
    echo -e "  bash $(basename "$0") <hostname|all> <keyword> [YYYY-MM-DD]"
    echo ""
    echo -e "${BOLD}Tham số:${NC}"
    echo -e "  hostname  : Tên host cụ thể hoặc 'all' để tìm tất cả host"
    echo -e "  keyword   : Từ khóa cần tìm (bắt buộc, hỗ trợ regex)"
    echo -e "  date      : Lọc theo ngày định dạng YYYY-MM-DD (tùy chọn)"
    echo ""
    echo -e "${BOLD}Ví dụ:${NC}"
    echo -e "  bash $(basename "$0") all \"Failed password\""
    echo -e "  bash $(basename "$0") web-client \"error\" 2024-01-15"
    echo -e "  bash $(basename "$0") all \"CRITICAL\" $(date +%Y-%m-%d)"
    exit 1
}

# --------------------------------------------------------------------------- #
# Kiểm tra tham số đầu vào
# --------------------------------------------------------------------------- #
if [[ $# -lt 2 ]]; then
    echo -e "${RED}❌ Thiếu tham số!${NC}"
    usage
fi

SEARCH_HOST="$1"
KEYWORD="$2"
SEARCH_DATE="${3:-}"   # Tham số thứ 3 là tùy chọn, mặc định rỗng

# --------------------------------------------------------------------------- #
# Kiểm tra thư mục log tồn tại
# --------------------------------------------------------------------------- #
if [[ ! -d "$LOG_DIR" ]]; then
    echo -e "${RED}❌ Thư mục $LOG_DIR không tồn tại!${NC}"
    echo -e "   Script này phải chạy trên Syslog Server (192.168.10.100)"
    exit 1
fi

# --------------------------------------------------------------------------- #
# Xác định danh sách host cần tìm kiếm
# --------------------------------------------------------------------------- #
if [[ "$SEARCH_HOST" == "all" ]]; then
    # Tìm tất cả host — lấy tên các thư mục con
    HOSTS=()
    while IFS= read -r -d '' dir; do
        HOSTS+=("$(basename "$dir")")
    done < <(find "$LOG_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)

    if [[ ${#HOSTS[@]} -eq 0 ]]; then
        echo -e "${YELLOW}⚠️  Không tìm thấy host nào trong $LOG_DIR${NC}"
        exit 0
    fi
else
    # Tìm một host cụ thể
    if [[ ! -d "$LOG_DIR/$SEARCH_HOST" ]]; then
        echo -e "${RED}❌ Host '$SEARCH_HOST' không tồn tại trong $LOG_DIR${NC}"
        echo -e "   Các host hiện có:"
        ls "$LOG_DIR" 2>/dev/null | while read -r h; do
            echo -e "   • $h"
        done
        exit 1
    fi
    HOSTS=("$SEARCH_HOST")
fi

# --------------------------------------------------------------------------- #
# Header kết quả tìm kiếm
# --------------------------------------------------------------------------- #
echo ""
echo -e "${CYAN}${BOLD}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║         TÌM KIẾM LOG — NHÓM 15                      ║${NC}"
echo -e "${CYAN}${BOLD}╚═══════════════════════════════════════════════════════╝${NC}"
echo -e "  ${BOLD}Host    :${NC} ${SEARCH_HOST}"
echo -e "  ${BOLD}Từ khóa :${NC} ${YELLOW}${KEYWORD}${NC}"
echo -e "  ${BOLD}Ngày    :${NC} ${SEARCH_DATE:-'(tất cả)'}"
echo -e "  ${BOLD}Tìm trong:${NC} $LOG_DIR"
echo ""

# --------------------------------------------------------------------------- #
# Biến đếm tổng số kết quả
# --------------------------------------------------------------------------- #
TOTAL_RESULTS=0

# --------------------------------------------------------------------------- #
# Hàm tìm kiếm trong một file log
# --------------------------------------------------------------------------- #
search_in_file() {
    local file="$1"
    local host="$2"
    local logtype="$3"

    if [[ ! -f "$file" || ! -s "$file" ]]; then
        return 0  # File không tồn tại hoặc trống — bỏ qua
    fi

    # Xây dựng lệnh grep
    # Dùng grep -i (case insensitive) và --color=always để highlight từ khóa
    local grep_cmd="grep -in --color=always"

    # Nếu có tham số ngày, lọc thêm theo ngày
    local results
    if [[ -n "$SEARCH_DATE" ]]; then
        # Lọc theo ngày trước, rồi tìm từ khóa
        results=$(grep "$SEARCH_DATE" "$file" 2>/dev/null | \
                  grep -i --color=always "$KEYWORD" 2>/dev/null || true)
    else
        results=$(grep -i --color=always "$KEYWORD" "$file" 2>/dev/null || true)
    fi

    if [[ -n "$results" ]]; then
        local count
        count=$(echo "$results" | wc -l)
        TOTAL_RESULTS=$((TOTAL_RESULTS + count))

        echo -e "  ${GREEN}▶ $host / $logtype${NC} — ${YELLOW}$count kết quả${NC}"
        echo -e "  ┌─────────────────────────────────────────────────────"
        echo "$results" | head -20 | while IFS= read -r line; do
            echo -e "  │ $line"
        done

        # Nếu có nhiều hơn 20 kết quả, thông báo còn thêm
        if [[ $count -gt 20 ]]; then
            echo -e "  │ ${YELLOW}... và $((count - 20)) kết quả khác${NC}"
        fi
        echo -e "  └─────────────────────────────────────────────────────"
        echo ""
    fi
}

# --------------------------------------------------------------------------- #
# Tìm kiếm trong từng host
# --------------------------------------------------------------------------- #
for host in "${HOSTS[@]}"; do
    HOST_DIR="$LOG_DIR/$host"
    echo -e "${BLUE}${BOLD}🔍 Tìm trong host: $host${NC}"

    # Tìm trong tất cả file log của host
    search_in_file "$HOST_DIR/syslog.log" "$host" "syslog.log"
    search_in_file "$HOST_DIR/auth.log"   "$host" "auth.log"
    search_in_file "$HOST_DIR/error.log"  "$host" "error.log"
done

# --------------------------------------------------------------------------- #
# Tìm trong file alert (luôn tìm nếu có)
# --------------------------------------------------------------------------- #
ALERT_DIR="/var/log/alerts"
if [[ -d "$ALERT_DIR" ]]; then
    echo -e "${BLUE}${BOLD}🔍 Tìm trong file cảnh báo (alerts):${NC}"
    search_in_file "$ALERT_DIR/brute_force.log" "ALERTS" "brute_force.log"
    search_in_file "$ALERT_DIR/critical.log"    "ALERTS" "critical.log"
fi

# --------------------------------------------------------------------------- #
# Tổng kết
# --------------------------------------------------------------------------- #
echo ""
echo -e "${CYAN}${BOLD}═══════════════════════════════════════════════════════${NC}"
if [[ $TOTAL_RESULTS -gt 0 ]]; then
    echo -e "  ${GREEN}${BOLD}Tổng kết quả tìm được: $TOTAL_RESULTS dòng${NC}"
    echo -e "  Từ khóa: ${YELLOW}\"$KEYWORD\"${NC}"
    [[ -n "$SEARCH_DATE" ]] && echo -e "  Ngày: $SEARCH_DATE"
else
    echo -e "  ${YELLOW}Không tìm thấy kết quả nào cho: \"$KEYWORD\"${NC}"
    [[ -n "$SEARCH_DATE" ]] && echo -e "  Ngày: $SEARCH_DATE"
fi
echo -e "${CYAN}${BOLD}═══════════════════════════════════════════════════════${NC}"
echo ""
