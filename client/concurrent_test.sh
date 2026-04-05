#!/usr/bin/env bash
# =============================================================================
# FILE    : client/concurrent_test.sh
# MỤC ĐÍCH: Gửi 200 log đồng thời từ nhiều client để kiểm tra Rsyslog Server
#           có xử lý đúng khi nhận log từ nhiều nguồn cùng lúc không
# CÁCH CHẠY: bash concurrent_test.sh <CLIENT_ID>
#            CLIENT_ID = 1 (web-client), 2 (app-client), 3 (db-client)
# VÍ DỤ   : bash concurrent_test.sh 1   ← chạy trên web-client
# LƯU Ý   : Chạy ĐỒNG THỜI trên cả 3 client để test concurrent load
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# Màu terminal
# --------------------------------------------------------------------------- #
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

# --------------------------------------------------------------------------- #
# Kiểm tra tham số CLIENT_ID
# --------------------------------------------------------------------------- #
if [[ $# -lt 1 ]]; then
    echo -e "${RED}❌ Thiếu CLIENT_ID!${NC}"
    echo "Cú pháp: bash $0 <CLIENT_ID>"
    echo "CLIENT_ID: 1 = web-client, 2 = app-client, 3 = db-client"
    exit 1
fi

CLIENT_ID="$1"

# Validate: CLIENT_ID phải là 1, 2 hoặc 3
if [[ ! "$CLIENT_ID" =~ ^[123]$ ]]; then
    echo -e "${RED}❌ CLIENT_ID không hợp lệ: $CLIENT_ID (chỉ dùng 1, 2, hoặc 3)${NC}"
    exit 1
fi

MY_HOST=$(hostname)
TOTAL_MESSAGES=200
SERVER_IP="192.168.10.100"

echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}  CONCURRENT LOG TEST — Client $CLIENT_ID ($MY_HOST)${NC}"
echo -e "${CYAN}============================================================${NC}"
echo -e "  Sẽ gửi: ${YELLOW}$TOTAL_MESSAGES dòng log${NC} đến $SERVER_IP"
echo -e "  Client ID: $CLIENT_ID"
echo ""
echo -e "${YELLOW}⚠️  Hãy chắc chắn 2 client kia cũng đang chạy script này!${NC}"
echo -e "  Đợi 3 giây rồi bắt đầu gửi..."
sleep 3

# --------------------------------------------------------------------------- #
# Ghi lại thời điểm bắt đầu để tính tổng thời gian
# --------------------------------------------------------------------------- #
TIME_START=$(date +%s%N)   # Timestamp nanosecond — dùng để đo thời gian chính xác

# --------------------------------------------------------------------------- #
# Hàm gửi một batch log trong background
#
# TẠI SAO dùng & (background / chạy nền)?
#   Vì mục tiêu là mô phỏng ĐỒNG THỜI: nếu dùng vòng lặp tuần tự (không có &),
#   client phải chờ từng lệnh logger hoàn thành mới gửi tiếp → giả lập
#   concurrent nhưng thực ra là sequential.
#   Dùng & → shell fork ra subprocess ngay lập tức, không chờ → nhiều logger
#   process chạy cùng lúc → server thực sự nhận log từ nhiều luồng song song.
#
# TẠI SAO cần SEQ number (số thứ tự)?
#   Vì sau này cần KIỂM TRA tính toàn vẹn:
#   - Nếu thiếu seq=042 → biết chính xác dòng đó bị mất (missing)
#   - Nếu seq=042 xuất hiện 2 lần → biết bị ghi trùng (duplicate)
#   - Nếu chỉ dùng nội dung chung chung → không phân biệt được mất/trùng
#   SEQ là "mã định danh duy nhất" cho mỗi log message trong test này.
# --------------------------------------------------------------------------- #
send_log_batch() {
    local start=$1
    local end=$2

    for seq in $(seq "$start" "$end"); do
        # Timestamp nanosecond: dùng date +%s.%N thay vì %s để có độ chính xác cao
        # TẠI SAO cần nanosecond? Để kiểm tra interleaving chính xác:
        # nếu 3 client gửi gần nhau, giây thường (epoch) có thể trùng nhau,
        # nanosecond giúp phân biệt thứ tự thực sự của log
        TS=$(date +%s.%N)

        # Format message chuẩn để server có thể grep và phân tích:
        # - CONCURRENT_TEST: tag để phân biệt với log khác
        # - seq=NNN: số thứ tự 3 chữ số (001-200), padding để sort alphabetically đúng
        # - client=N: client ID để server đếm riêng từng client
        # - host=...: hostname để double-check
        # - ts=...: timestamp nanosecond để kiểm tra thứ tự
        MSG=$(printf "CONCURRENT_TEST seq=%03d client=%s host=%s ts=%s" \
              "$seq" "$CLIENT_ID" "$MY_HOST" "$TS")

        # Gửi qua UDP (user.info) — UDP nhanh hơn TCP, phù hợp test throughput
        # TẠI SAO UDP cho concurrent test? Vì chúng ta muốn đo khả năng xử lý
        # của SERVER, không phải kiểm tra reliability của network
        logger -p user.info -t "concurrent-test" "$MSG" &
        # Dấu & ở cuối: fork subprocess, không chờ logger xong mới tiếp tục
        # → nhiều logger chạy song song → tạo đúng tải concurrent
    done

    # Chờ tất cả background jobs trong batch này hoàn thành
    # TẠI SAO cần wait? Để đảm bảo mọi logger đã gửi xong trước khi đo thời gian
    wait
}

# --------------------------------------------------------------------------- #
# Gửi log theo 4 batch song song
# Chia 200 message thành 4 batch × 50 để tạo concurrent load thực sự
# --------------------------------------------------------------------------- #
echo -e "${GREEN}▶ Bắt đầu gửi log concurrent...${NC}"

# Chạy 4 batch trong background để chúng thực sự chạy đồng thời
send_log_batch 1   50  &   # Batch 1: seq 001-050
BATCH1_PID=$!
send_log_batch 51  100 &   # Batch 2: seq 051-100
BATCH2_PID=$!
send_log_batch 101 150 &   # Batch 3: seq 101-150
BATCH3_PID=$!
send_log_batch 151 200 &   # Batch 4: seq 151-200
BATCH4_PID=$!

# Hiển thị progress trong khi chờ
echo -n "  Đang gửi"
while kill -0 $BATCH1_PID 2>/dev/null || \
      kill -0 $BATCH2_PID 2>/dev/null || \
      kill -0 $BATCH3_PID 2>/dev/null || \
      kill -0 $BATCH4_PID 2>/dev/null; do
    echo -n "."
    sleep 0.5
done
echo ""

# --------------------------------------------------------------------------- #
# Tính thời gian gửi
# --------------------------------------------------------------------------- #
TIME_END=$(date +%s%N)
# Tính thời gian bằng giây với 3 chữ số thập phân
ELAPSED=$(echo "scale=3; ($TIME_END - $TIME_START) / 1000000000" | bc)

# --------------------------------------------------------------------------- #
# Kết quả
# --------------------------------------------------------------------------- #
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  HOÀN THÀNH GỬI LOG${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "  Client ID   : $CLIENT_ID ($MY_HOST)"
echo -e "  Tổng đã gửi : ${YELLOW}$TOTAL_MESSAGES dòng${NC}"
echo -e "  Thời gian   : ${YELLOW}${ELAPSED}s${NC}"
echo -e "  Throughput  : $(echo "scale=1; $TOTAL_MESSAGES / $ELAPSED" | bc) msg/s"
echo ""
echo -e "  Kiểm tra trên SERVER:"
echo -e "  ${CYAN}grep 'client=$CLIENT_ID' /var/log/remote/$MY_HOST/syslog.log | wc -l${NC}"
echo -e "  ${CYAN}bash server/verify_concurrent.sh${NC}"
echo -e "${GREEN}============================================================${NC}"
