# Centralized Logging System — Nhóm 15

> **Đồ án môn học** | Hệ thống thu thập log tập trung dùng Rsyslog  
> Kiến trúc: 1 Syslog Server + 3 Client | Ubuntu 22.04 LTS | VMware/VirtualBox

---

## 1. Sơ đồ kiến trúc mạng

```
  192.168.10.101          192.168.10.102          192.168.10.103
┌───────────────┐        ┌───────────────┐        ┌───────────────┐
│  web-client   │        │  app-client   │        │   db-client   │
│  Client 1     │        │  Client 2     │        │  Client 3     │
│  (Web Server) │        │  (App Server) │        │ (DB Server)   │
└───────┬───────┘        └───────┬───────┘        └───────┬───────┘
        │  UDP/514                │  TCP/514               │  TCP+UDP
        │  TCP/514                │                        │
        └────────────────┬────────┘────────────────────────┘
                         │
                  ┌──────▼──────┐
                  │   SWITCH    │
                  │ 192.168.10.x│
                  └──────┬──────┘
                         │
              ┌──────────▼──────────┐
              │    SYSLOG SERVER    │
              │   192.168.10.100    │
              │  /var/log/remote/   │
              │  /var/log/alerts/   │
              │  Rsyslog v8.x       │
              │  UDP/514 + TCP/514  │
              └─────────────────────┘
```

**Luồng log:**
- Tất cả `*.*` → UDP/514 → `/var/log/remote/<hostname>/syslog.log`
- `auth.*` + `*.crit` → TCP/514 (có Disk Queue) → `auth.log` + `error.log`
- `Failed password` → `/var/log/alerts/brute_force.log`
- Severity 0-2 → `/var/log/alerts/critical.log`

---

## 2. Bảng phân bổ IP

| Máy         | Hostname       | IP Address       | Vai trò                     |
|-------------|----------------|------------------|-----------------------------|
| Server      | syslog-server  | 192.168.10.100   | Syslog Server — nhận log    |
| Client 1    | web-client     | 192.168.10.101   | Web Server — gửi log        |
| Client 2    | app-client     | 192.168.10.102   | App Server — gửi log        |
| Client 3    | db-client      | 192.168.10.103   | Database Server — gửi log   |
| Gateway     | —              | 192.168.10.1     | Router mạng lab             |

**Network:** `192.168.10.0/24`  
**Port:** UDP/514 và TCP/514 (Syslog standard)

---

## 3. Hướng dẫn cài đặt từng bước

### Yêu cầu hệ thống
- RAM tối thiểu: 8GB (4 VM × 1-2GB)
- Phần mềm: VMware Workstation hoặc VirtualBox
- OS mỗi VM: Ubuntu Server 22.04 LTS
- Network: Tất cả VM cùng Host-Only hoặc Internal Network `192.168.10.0/24`

---

### PHẦN A — Cài đặt Syslog Server (192.168.10.100)

**1. Tạo VM Server trong VMware/VirtualBox**
```
CPU: 2 core | RAM: 1GB | Disk: 20GB
Network: Host-Only Adapter (192.168.10.x)
```

**2. Đăng nhập vào VM Server và clone repo**
```bash
git clone <repo-url> centralized-logging
cd centralized-logging
```

**3. Cấp quyền thực thi cho script**
```bash
chmod +x server/setup_server.sh
chmod +x server/verify_logs.sh
```

**4. Chạy script cài đặt server**
```bash
sudo bash server/setup_server.sh
```

**5. Xác nhận server hoạt động**
```bash
sudo systemctl status rsyslog
sudo ss -ulnp | grep 514     # Kiểm tra UDP port
sudo ss -tlnp | grep 514     # Kiểm tra TCP port
sudo ufw status              # Kiểm tra firewall
```

---

### PHẦN B — Cài đặt Client 1 (web-client: 192.168.10.101)

**6. Tạo VM Client 1 trong VMware/VirtualBox**
```
CPU: 1 core | RAM: 512MB-1GB | Disk: 10GB
Network: cùng Host-Only với Server
```

**7. Đăng nhập vào VM Client 1, clone repo**
```bash
git clone <repo-url> centralized-logging
cd centralized-logging
chmod +x client/setup_client.sh
chmod +x client/test_send_log.sh
```

**8. Chạy script cài đặt client**
```bash
sudo bash client/setup_client.sh 192.168.10.101 web-client
```

**9. Lặp lại bước 6-8 cho Client 2 (app-client)**
```bash
sudo bash client/setup_client.sh 192.168.10.102 app-client
```

**10. Lặp lại bước 6-8 cho Client 3 (db-client)**
```bash
sudo bash client/setup_client.sh 192.168.10.103 db-client
```

---

### PHẦN C — Kiểm tra kết nối mạng

**11. Từ mỗi client, ping đến server**
```bash
ping -c 4 192.168.10.100
```

**12. Từ mỗi client, kiểm tra kết nối port 514**
```bash
nc -zv 192.168.10.100 514   # Kiểm tra TCP
```

**13. Gửi log test thủ công**
```bash
logger -p user.info "Test kết nối từ $(hostname)"
```

**14. Kiểm tra log trên server**
```bash
# Trên server (192.168.10.100):
tail -f /var/log/remote/*/syslog.log
```

---

## 4. Hướng dẫn kiểm thử và Demo

### Demo 5 bước

**BƯỚC 1 — Mở 2 terminal song song**
```bash
# Terminal 1 (trên SERVER): Theo dõi log realtime
tail -f /var/log/remote/*/syslog.log

# Terminal 2 (trên bất kỳ CLIENT): Chạy test
bash client/test_send_log.sh
```

**BƯỚC 2 — Quan sát log xuất hiện realtime trên Terminal 1**
```
Sau khi chạy test_send_log.sh, Terminal 1 sẽ hiển thị log đến từ client
Kiểm tra hostname trong log có khớp với tên client không
```

**BƯỚC 3 — Kiểm tra phân loại log**
```bash
# Trên server:
ls /var/log/remote/                         # Danh sách host
ls /var/log/remote/web-client/              # File log của web-client
wc -l /var/log/remote/web-client/syslog.log # Đếm số dòng
cat /var/log/remote/web-client/auth.log     # Xem auth log
cat /var/log/remote/web-client/error.log    # Xem error log
```

**BƯỚC 4 — Kiểm tra hệ thống cảnh báo**
```bash
# Trên server:
cat /var/log/alerts/brute_force.log   # Xem log brute-force
cat /var/log/alerts/critical.log      # Xem log critical
```

**BƯỚC 5 — Demo tìm kiếm log**
```bash
# Trên server, cài quyền:
chmod +x tools/search_log.sh

# Tìm tất cả Failed password:
bash tools/search_log.sh all "Failed password"

# Tìm lỗi trên web-client hôm nay:
bash tools/search_log.sh web-client "error" $(date +%Y-%m-%d)

# Tìm CRITICAL trên tất cả host:
bash tools/search_log.sh all "CRITICAL"
```

**BƯỚC 6 — Chạy verify script để tổng kết**
```bash
# Trên server:
bash server/verify_logs.sh
```

---

## 5. Cấu trúc thư mục log trên Server

```
/var/log/
├── remote/                        ← Log từ các client
│   ├── web-client/                ← Client 1 (192.168.10.101)
│   │   ├── syslog.log             ← Tất cả log từ web-client
│   │   ├── auth.log               ← Log xác thực (SSH, sudo)
│   │   └── error.log              ← Log severity Error trở lên
│   ├── app-client/                ← Client 2 (192.168.10.102)
│   │   ├── syslog.log
│   │   ├── auth.log
│   │   └── error.log
│   └── db-client/                 ← Client 3 (192.168.10.103)
│       ├── syslog.log
│       ├── auth.log
│       └── error.log
└── alerts/                        ← Log cảnh báo bảo mật
    ├── brute_force.log            ← SSH brute-force (Failed password)
    └── critical.log               ← Emergency/Alert/Critical events

/var/spool/rsyslog/                ← Disk Queue khi server ngắt kết nối
├── fwdRule_auth.qi                ← Queue metadata
├── fwdRule_auth-00000001.qf       ← Queue data
└── fwdRule_crit.qi
```

**Logrotate:** Tất cả file trong `/var/log/remote/` và `/var/log/alerts/` được rotate hàng ngày, giữ 30 ngày, nén bằng gzip.

---

## 6. Bảng giải thích các file cấu hình quan trọng

| File | Vị trí (trên Server) | Mục đích |
|------|---------------------|----------|
| `rsyslog.conf` | `/etc/rsyslog.conf` | Cấu hình chính: nhận UDP/TCP, template, rule phân loại log |
| `alert_rules.conf` | `/etc/rsyslog.d/99-alerts.conf` | Rule phát hiện brute-force và lỗi Critical |
| `rsyslog-remote.logrotate` | `/etc/logrotate.d/rsyslog-remote` | Tự động xoay vòng file log hàng ngày |

| File | Vị trí (trên Client) | Mục đích |
|------|----------------------|----------|
| `rsyslog-client.conf` | `/etc/rsyslog.d/99-remote.conf` | Gửi log đến server qua UDP và TCP với Disk Queue |

| Script | Chạy trên | Mục đích |
|--------|-----------|----------|
| `server/setup_server.sh` | Server | Cài đặt tự động toàn bộ Syslog Server |
| `client/setup_client.sh` | Client | Cài đặt client, nhận IP và hostname làm tham số |
| `client/test_send_log.sh` | Client | Gửi log test đa cấp độ để kiểm tra hệ thống |
| `server/verify_logs.sh` | Server | Kiểm tra và hiển thị trạng thái log từng host |
| `tools/search_log.sh` | Server | Tìm kiếm log theo host, keyword, và ngày |

---

## 7. Troubleshooting

**Log không xuất hiện trên server:**
```bash
# Kiểm tra rsyslog client có chạy không:
systemctl status rsyslog

# Kiểm tra kết nối mạng:
ping 192.168.10.100
nc -zv 192.168.10.100 514

# Kiểm tra firewall server:
sudo ufw status
```

**Rsyslog không khởi động:**
```bash
# Kiểm tra cú pháp cấu hình:
rsyslogd -N1

# Xem log lỗi:
journalctl -u rsyslog -n 50
```

**Disk Queue đầy:**
```bash
# Xem dung lượng queue:
ls -lh /var/spool/rsyslog/

# Kiểm tra kết nối đến server:
systemctl status rsyslog | grep "connecting"
```

---

*Nhóm 15 — Đồ án môn học Quản trị Hệ thống*
