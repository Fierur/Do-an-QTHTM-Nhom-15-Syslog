#!/usr/bin/env bash
# =============================================================================
# FILE    : server/sign_client_certs.sh
# MỤC ĐÍCH: Chạy TRÊN SERVER — tự động tạo và ký cert cho cả 3 client qua SSH
#           Giải quyết vấn đề gốc rễ: ca.key chỉ có trên server, không trên client
# CÁCH CHẠY: sudo bash server/sign_client_certs.sh
# YÊU CẦU : SSH key đã được setup từ server đến 3 client (ssh-copy-id)
#
# LUỒNG KÝ CERT:
#   Server SSH → Client: tạo key + CSR
#   SCP CSR về server → ký bằng ca.key → SCP cert về client
#   → Client có cert hợp lệ mà không cần ca.key
#
# TẠI SAO không để client tự ký?
#   → ca.key là private key của CA, KHÔNG nên copy sang client (bảo mật)
#   → Nếu ca.key bị lộ → kẻ tấn công tự ký cert giả và kết nối được
#   → Server giữ ca.key, ký tập trung = đúng mô hình PKI
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
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "${GREEN}✅ $1${NC}"; }
fail() { echo -e "${RED}❌ $1${NC}"; exit 1; }
info() { echo -e "${BLUE}➡  $1${NC}"; }
warn() { echo -e "${YELLOW}⚠  $1${NC}"; }

# --------------------------------------------------------------------------- #
# CẤU HÌNH — Sửa SSH_USER nếu username VM khác
# --------------------------------------------------------------------------- #
SSH_USER="adw"          # Username trên các VM client — sửa nếu cần
CERT_DIR="/etc/stunnel/certs"
CA_CRT="${CERT_DIR}/ca.crt"
CA_KEY="${CERT_DIR}/ca.key"

# Map hostname → IP — thêm/bớt client tại đây
declare -A CLIENTS
CLIENTS["web-client"]="192.168.10.101"
CLIENTS["app-client"]="192.168.10.102"
CLIENTS["db-client"]="192.168.10.103"

# Tham số SSH dùng chung — StrictHostKeyChecking=no để không hỏi fingerprint
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes"

# Theo dõi kết quả từng client
declare -A RESULTS

# --------------------------------------------------------------------------- #
# Kiểm tra quyền root
# --------------------------------------------------------------------------- #
[[ $EUID -ne 0 ]] && fail "Cần quyền root. Chạy: sudo bash $0"

echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   KÝ CERT CHO 3 CLIENT — SIGN_CLIENT_CERTS.SH              ║"
echo "║   Chạy trên Syslog Server 192.168.10.100                   ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# --------------------------------------------------------------------------- #
# BƯỚC 1: Kiểm tra CA key/cert tồn tại trên server
# TẠI SAO kiểm tra trước? Vì nếu ca.key mất → ký được cert nhưng verify sẽ fail
# Phát hiện sớm tránh mất thời gian SSH vào từng client
# --------------------------------------------------------------------------- #
info "Bước 1: Kiểm tra CA tại $CERT_DIR..."

[[ -f "$CA_KEY" ]]  || fail "ca.key không tồn tại tại $CA_KEY — chạy setup_tls_server.sh trước"
[[ -f "$CA_CRT" ]]  || fail "ca.crt không tồn tại tại $CA_CRT — chạy setup_tls_server.sh trước"

# Kiểm tra ca.key và ca.crt là đúng cặp (không bị thay thế nhầm)
# TẠI SAO quan trọng? Nếu key/cert không cùng cặp → cert ký ra sẽ không verify được
CA_KEY_MOD=$(openssl rsa -noout -modulus -in "$CA_KEY" 2>/dev/null | md5sum)
CA_CRT_MOD=$(openssl x509 -noout -modulus -in "$CA_CRT" 2>/dev/null | md5sum)
if [[ "$CA_KEY_MOD" != "$CA_CRT_MOD" ]]; then
    fail "ca.key và ca.crt KHÔNG cùng cặp! Tạo lại CA bằng setup_tls_server.sh"
fi

ok "CA key/cert hợp lệ và cùng cặp"
echo ""

# --------------------------------------------------------------------------- #
# BƯỚC 2: Kiểm tra SSH key đến từng client
# TẠI SAO dùng BatchMode=yes? Ngăn SSH hỏi password → script chạy tự động
# Nếu SSH hỏi password trong BatchMode → lỗi ngay → phát hiện sớm
# --------------------------------------------------------------------------- #
info "Bước 2: Kiểm tra kết nối SSH đến 3 client..."

SSH_OK=true
for HOSTNAME in "${!CLIENTS[@]}"; do
    IP="${CLIENTS[$HOSTNAME]}"
    if ssh $SSH_OPTS "${SSH_USER}@${IP}" "echo ok" &>/dev/null; then
        ok "SSH đến $HOSTNAME ($IP) OK"
    else
        echo -e "  ${RED}❌ SSH đến $HOSTNAME ($IP) THẤT BẠI${NC}"
        SSH_OK=false
    fi
done

if [[ "$SSH_OK" == "false" ]]; then
    echo ""
    echo -e "${YELLOW}${BOLD}  Cần setup SSH key trước khi chạy script này:${NC}"
    echo ""
    echo -e "  ${CYAN}# Bước 1: Tạo SSH key (bỏ qua nếu đã có)${NC}"
    echo -e "  ssh-keygen -t rsa -b 2048 -N \"\" -f ~/.ssh/id_rsa"
    echo ""
    echo -e "  ${CYAN}# Bước 2: Copy key sang từng client (nhập password lần cuối)${NC}"
    for HOSTNAME in "${!CLIENTS[@]}"; do
        IP="${CLIENTS[$HOSTNAME]}"
        echo -e "  ssh-copy-id ${SSH_USER}@${IP}"
    done
    echo ""
    echo -e "  ${CYAN}# Bước 3: Chạy lại script này${NC}"
    echo -e "  sudo bash $0"
    exit 1
fi

ok "SSH đến cả 3 client thành công"
echo ""

# --------------------------------------------------------------------------- #
# BƯỚC 3: Ký cert cho từng client
# --------------------------------------------------------------------------- #
info "Bước 3: Ký cert cho từng client..."
echo ""

for HOSTNAME in "${!CLIENTS[@]}"; do
    IP="${CLIENTS[$HOSTNAME]}"
    CLIENT_KEY="${CERT_DIR}/client-${HOSTNAME}.key"
    CLIENT_CRT_REMOTE="${CERT_DIR}/client-${HOSTNAME}.crt"
    CLIENT_CRT_LOCAL="/tmp/client-${HOSTNAME}.crt"
    CLIENT_CSR_REMOTE="/tmp/client-${HOSTNAME}.csr"
    CLIENT_CSR_LOCAL="/tmp/client-${HOSTNAME}.csr"

    echo -e "${CYAN}${BOLD}  ── Xử lý: $HOSTNAME ($IP) ──${NC}"

    # ----------------------------------------------------------------
    # Idempotent check: nếu cert đã tồn tại VÀ hợp lệ → skip
    # TẠI SAO cần verify thay vì chỉ check tồn tại?
    # → Cert có thể tồn tại nhưng ký bởi CA cũ (đã tạo lại CA)
    # → verify đảm bảo cert hiện tại khớp với CA hiện tại
    # ----------------------------------------------------------------
    CERT_EXISTS=$(ssh $SSH_OPTS "${SSH_USER}@${IP}" \
        "test -f '${CLIENT_CRT_REMOTE}' && echo yes || echo no" 2>/dev/null)

    if [[ "$CERT_EXISTS" == "yes" ]]; then
        # Copy cert về server để verify
        scp -q $SSH_OPTS "${SSH_USER}@${IP}:${CLIENT_CRT_REMOTE}" \
            "${CLIENT_CRT_LOCAL}" 2>/dev/null || true

        if [[ -f "$CLIENT_CRT_LOCAL" ]] && \
           openssl verify -CAfile "$CA_CRT" "$CLIENT_CRT_LOCAL" 2>/dev/null | grep -q "OK"; then
            ok "$HOSTNAME: cert đã tồn tại và hợp lệ — bỏ qua (idempotent)"
            RESULTS[$HOSTNAME]="✅ OK (đã có sẵn)"
            rm -f "$CLIENT_CRT_LOCAL"
            echo ""
            continue
        else
            warn "$HOSTNAME: cert tồn tại nhưng KHÔNG hợp lệ — tạo lại"
            rm -f "$CLIENT_CRT_LOCAL"
        fi
    fi

    # ----------------------------------------------------------------
    # Tạo thư mục cert trên client
    # ----------------------------------------------------------------
    ssh $SSH_OPTS "${SSH_USER}@${IP}" \
        "sudo mkdir -p '${CERT_DIR}' && sudo chmod 700 '${CERT_DIR}'" \
        2>/dev/null
    ok "$HOSTNAME: thư mục $CERT_DIR đã sẵn sàng"

    # ----------------------------------------------------------------
    # Tạo private key VÀ CSR ngay trên client
    # TẠI SAO tạo key trên client thay vì server?
    # → Private key KHÔNG nên rời khỏi máy chủ của nó
    # → Tạo trên client → key không bao giờ đi qua mạng
    # → Chỉ CSR (public) và cert (public) mới được copy qua lại
    # ----------------------------------------------------------------
    ssh $SSH_OPTS "${SSH_USER}@${IP}" bash <<REMOTE_CMD
        set -e
        # Tạo private key 2048-bit RSA
        sudo openssl genrsa -out "${CERT_DIR}/client-${HOSTNAME}.key" 2048 2>/dev/null
        sudo chmod 600 "${CERT_DIR}/client-${HOSTNAME}.key"
        # Tạo CSR — CN phải khớp hostname để dễ nhận dạng trong log
        sudo openssl req -new \
            -key "${CERT_DIR}/client-${HOSTNAME}.key" \
            -out "${CLIENT_CSR_REMOTE}" \
            -subj "/C=VN/ST=HoChiMinh/O=Nhom15Lab/CN=${HOSTNAME}" \
            2>/dev/null
        # Cho phép user đọc CSR để scp
        sudo chmod 644 "${CLIENT_CSR_REMOTE}"
REMOTE_CMD
    ok "$HOSTNAME: key + CSR đã tạo trên client"

    # ----------------------------------------------------------------
    # Copy CSR từ client về server để ký
    # ----------------------------------------------------------------
    scp -q $SSH_OPTS "${SSH_USER}@${IP}:${CLIENT_CSR_REMOTE}" \
        "${CLIENT_CSR_LOCAL}"
    ok "$HOSTNAME: CSR đã copy về server"

    # ----------------------------------------------------------------
    # Ký CSR bằng ca.key trên server → tạo cert
    # TẠI SAO -CAcreateserial?
    # → OpenSSL cần file .srl để theo dõi serial number của cert
    # → -CAcreateserial tự tạo file này nếu chưa có
    # → Serial number unique giúp phân biệt các cert trong log
    # ----------------------------------------------------------------
    openssl x509 -req \
        -in "${CLIENT_CSR_LOCAL}" \
        -CA "$CA_CRT" \
        -CAkey "$CA_KEY" \
        -CAcreateserial \
        -out "${CLIENT_CRT_LOCAL}" \
        -days 3650 \
        2>/dev/null
    ok "$HOSTNAME: cert đã ký bởi CA"

    # ----------------------------------------------------------------
    # Verify cert ngay sau khi ký — phát hiện lỗi sớm
    # ----------------------------------------------------------------
    if ! openssl verify -CAfile "$CA_CRT" "$CLIENT_CRT_LOCAL" 2>/dev/null | grep -q "OK"; then
        fail "$HOSTNAME: cert ký xong nhưng verify THẤT BẠI — kiểm tra ca.key/ca.crt"
    fi
    ok "$HOSTNAME: cert verify OK"

    # ----------------------------------------------------------------
    # Copy cert đã ký VÀ ca.crt sang client
    # TẠI SAO copy ca.crt? Client cần ca.crt để xác thực cert của server
    # ----------------------------------------------------------------
    scp -q $SSH_OPTS "${CLIENT_CRT_LOCAL}" \
        "${SSH_USER}@${IP}:${CLIENT_CRT_REMOTE}" 2>/dev/null || \
    ssh $SSH_OPTS "${SSH_USER}@${IP}" \
        "sudo tee '${CLIENT_CRT_REMOTE}' > /dev/null" < "${CLIENT_CRT_LOCAL}"

    scp -q $SSH_OPTS "$CA_CRT" \
        "${SSH_USER}@${IP}:${CERT_DIR}/ca.crt" 2>/dev/null || \
    ssh $SSH_OPTS "${SSH_USER}@${IP}" \
        "sudo tee '${CERT_DIR}/ca.crt' > /dev/null" < "$CA_CRT"

    # Đặt quyền đúng cho cert trên client
    ssh $SSH_OPTS "${SSH_USER}@${IP}" \
        "sudo chmod 644 '${CLIENT_CRT_REMOTE}' '${CERT_DIR}/ca.crt'" 2>/dev/null

    ok "$HOSTNAME: cert + ca.crt đã copy sang client"

    # ----------------------------------------------------------------
    # Dọn file tạm
    # ----------------------------------------------------------------
    rm -f "${CLIENT_CSR_LOCAL}" "${CLIENT_CRT_LOCAL}"

    RESULTS[$HOSTNAME]="✅ OK"
    echo ""
done

# --------------------------------------------------------------------------- #
# BƯỚC 4: Bảng tổng kết
# --------------------------------------------------------------------------- #
echo -e "${GREEN}${BOLD}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║   KẾT QUẢ KÝ CERT CHO 3 CLIENT                     ║"
echo "╠══════════════════════════════════════════════════════╣"
for HOSTNAME in "${!CLIENTS[@]}"; do
    IP="${CLIENTS[$HOSTNAME]}"
    STATUS="${RESULTS[$HOSTNAME]:-❌ THẤT BẠI}"
    printf "║  %-20s (%s) : %-12s  ║\n" "$HOSTNAME" "$IP" "$STATUS"
done
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "${CYAN}Tiếp theo: chạy trên từng client:${NC}"
for HOSTNAME in "${!CLIENTS[@]}"; do
    IP="${CLIENTS[$HOSTNAME]}"
    echo -e "  sudo bash tls/setup_tls_client.sh $IP $HOSTNAME"
done
