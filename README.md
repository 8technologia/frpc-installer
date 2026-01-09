# FRPC Auto-Installer v2.5

Script tự động cài đặt và cấu hình frpc với random ports, health check tự động, và webhook notifications.

## Tính năng

- ✅ Tự động phát hiện kiến trúc CPU (amd64, arm64, arm)
- ✅ Tải phiên bản frpc mới nhất từ GitHub
- ✅ Random port: SOCKS5 (51xxx), HTTP (52xxx), Admin (53xxx)
- ✅ Random username/password
- ✅ Systemd auto-start khi boot
- ✅ Health check mỗi 2 phút với auto-restart
- ✅ Rate limiting: tối đa 5 restarts/giờ
- ✅ Webhook thông báo: cài đặt, down, up, rate limit
- ✅ Retry download 3 lần
- ✅ Kiểm tra network, disk space
- ✅ Update mode, Uninstall mode

## Cài đặt

### Cài mới (bắt buộc `--server`)

```bash
curl -fsSL https://raw.githubusercontent.com/8technologia/frpc-installer/master/install.sh | sudo bash -s -- \
  --server "IP:PORT:TOKEN"
```

### Đầy đủ tham số (khuyến nghị)

```bash
curl -fsSL https://raw.githubusercontent.com/8technologia/frpc-installer/master/install.sh | sudo bash -s -- \
  --server "103.166.185.156:7000:your_token" \
  --name "Box-HaNoi-01" \
  --webhook "https://webhook.site/your-id"
```

### Cập nhật binary (giữ config)

```bash
curl -fsSL https://raw.githubusercontent.com/8technologia/frpc-installer/master/install.sh | sudo bash -s -- --update
```

### Gỡ cài đặt

```bash
curl -fsSL https://raw.githubusercontent.com/8technologia/frpc-installer/master/install.sh | sudo bash -s -- --uninstall
```

## Tham số

| Tham số | Bắt buộc | Mô tả |
|---------|----------|-------|
| `--server "IP:PORT:TOKEN"` | ✅ (cài mới) | Server FRP |
| `--name "Box Name"` | ❌ | Tên box (mặc định: Box-hostname-xxx) |
| `--webhook "URL"` | ❌ | URL nhận thông báo |
| `--update` | ❌ | Chỉ cập nhật binary |
| `--uninstall` | ❌ | Gỡ cài đặt |

## Webhook Events

| Event | Mô tả | Có logs |
|-------|-------|---------|
| `install_success` | Cài đặt thành công | ❌ |
| `install_failed` | Cài đặt thất bại | ✅ |
| `update_complete` | Cập nhật binary xong | ❌ |
| `frpc_down` | frpc ngừng hoạt động | ✅ |
| `frpc_up` | frpc khôi phục | ❌ |
| `frpc_rate_limit` | Đạt giới hạn restart | ✅ |

### 1. Cài đặt thành công

```json
{
  "event": "install_success",
  "status": "success",
  "box_name": "Box-HaNoi-01",
  "frpc_version": "0.66.0",
  "public_ip": "123.45.67.89",
  "proxies": {
    "socks5": { "port": 51234, "username": "...", "password": "..." },
    "http": { "port": 52234, "username": "...", "password": "..." },
    "admin_api": { "port": 53234, "username": "admin", "password": "..." }
  },
  "frpc_running": true,
  "proxies_registered": 3
}
```

### 2. Cài đặt thất bại (có logs)

```json
{
  "event": "install_failed",
  "status": "failed",
  "error": "token mismatch",
  "frpc_logs": "Jan 09 17:30:01 sv1 frpc[1234]: login failed|Jan 09 17:30:01 sv1 frpc[1234]: token mismatch|..."
}
```

### 3. frpc Down (có logs)

```json
{
  "event": "frpc_down",
  "message": "frpc is not responding",
  "box_name": "Box-HaNoi-01",
  "frpc_logs": "Jan 09 17:30:01 sv1 frpc[1234]: connection lost|..."
}
```

### 4. frpc Khôi phục

```json
{
  "event": "frpc_up",
  "message": "frpc restarted successfully",
  "box_name": "Box-HaNoi-01"
}
```

### 5. Rate Limit (có logs)

```json
{
  "event": "frpc_rate_limit",
  "message": "Rate limit reached (5 restarts/hour). Manual intervention required.",
  "frpc_logs": "..."
}
```

## Health Check

Script tự động tạo health check:

| Thành phần | Chi tiết |
|------------|----------|
| Script | `/opt/frpc/healthcheck.sh` |
| Cron | Chạy mỗi 2 phút |
| Rate limit | Tối đa 5 restarts/giờ |
| Log | `/var/log/frpc-healthcheck.log` |
| Webhook URL | `/opt/frpc/.webhook_url` |

### Thêm webhook thủ công (nếu quên khi cài)

```bash
echo "https://webhook.site/your-id" > /opt/frpc/.webhook_url
```

### Xem log health check

```bash
tail -f /var/log/frpc-healthcheck.log
```

## Quản lý service

```bash
systemctl status frpc      # Xem status
systemctl restart frpc     # Restart
systemctl stop frpc        # Dừng (để test health check)
journalctl -u frpc -f      # Xem logs frpc
cat /opt/frpc/frpc.toml    # Xem config
```

## Yêu cầu FRP Server

```toml
# frps.toml
bindPort = 7000

# Authentication (BẮT BUỘC - phải khớp với token trong --server)
auth.method = "token"
auth.token = "your_secret_token"

# Cho phép port range cho boxes
allowPorts = [
  { start = 51001, end = 51999 },
  { start = 52001, end = 52999 },
  { start = 53001, end = 53999 }
]

# Optional: Web Dashboard
webServer.addr = "0.0.0.0"
webServer.port = 7500
webServer.user = "admin"
webServer.password = "admin123"
```

**Lưu ý:**

- `auth.token` trong frps.toml **PHẢI KHỚP** với token trong `--server "IP:PORT:TOKEN"`
- Nếu không khớp → frpc báo lỗi "token mismatch"
- Nếu port ngoài `allowPorts` → frpc báo lỗi "port not allowed"

## Cấu trúc thư mục

```
/opt/frpc/
├── frpc                 # Binary
├── frpc.toml            # Config
├── healthcheck.sh       # Health check script
├── .webhook_url         # Webhook URL (nếu có)
├── .frpc_down           # Flag đánh dấu đang down
└── .healthcheck_state   # Lịch sử restart

/var/log/
└── frpc-healthcheck.log # Log health check

/etc/systemd/system/
└── frpc.service         # Systemd service
```

## Troubleshooting

### Token mismatch

```bash
# Kiểm tra token
grep token /opt/frpc/frpc.toml
# Sửa nếu cần
nano /opt/frpc/frpc.toml
systemctl restart frpc
```

### Port not allowed

```bash
# Thêm vào frps.toml trên server:
allowPorts = [{ start = 51001, end = 53999 }]
systemctl restart frps
```

### Health check không gửi webhook

```bash
# Kiểm tra file webhook
cat /opt/frpc/.webhook_url
# Nếu không có, thêm thủ công:
echo "https://your-webhook-url" > /opt/frpc/.webhook_url
```

## License

MIT
