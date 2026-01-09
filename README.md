# FRPC Auto-Installer v3.2

Script tự động cài đặt và cấu hình frpc client với đầy đủ tính năng production-ready.

## ✅ Tính năng

- **Zero-touch Installation**: Cài đặt hoàn toàn tự động với 1 lệnh
- **Auto Architecture Detection**: Hỗ trợ amd64, arm64, arm
- **Random Ports**: SOCKS5 (51xxx), HTTP (52xxx), Admin (53xxx)
- **Port Retry**: Tự động thử port khác nếu bị trùng (max 3 lần)
- **Random Credentials**: Username/password ngẫu nhiên mỗi lần cài
- **Health Check**: Kiểm tra mỗi 2 phút, tự động restart
- **Rate Limiting**: Tối đa 5 restarts/giờ (tránh restart loop)
- **Webhook Notifications**: Gửi thông báo khi cài/down/up/rate_limit
- **Log Rotation**: Tự động rotate log khi >1MB
- **Update Mode**: Cập nhật binary, giữ nguyên config
- **Uninstall Mode**: Gỡ sạch sẽ

## 🚀 Cài đặt

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

## 📋 Tham số

| Tham số | Bắt buộc | Mô tả |
|---------|----------|-------|
| `--server "IP:PORT:TOKEN"` | ✅ (cài mới) | Server FRP và token xác thực |
| `--name "Box Name"` | ❌ | Tên box (mặc định: Box-hostname-xxx) |
| `--webhook "URL"` | ❌ | URL nhận webhook notifications |
| `--update` | ❌ | Chỉ cập nhật binary, giữ config |
| `--uninstall` | ❌ | Gỡ cài đặt hoàn toàn |

## 🔔 Webhook Events

| Event | Nguồn | Có logs | Mô tả |
|-------|-------|---------|-------|
| `install_success` | Installer | ❌ | Cài đặt thành công |
| `install_failed` | Installer | ✅ | Cài đặt thất bại |
| `update_complete` | Installer | ❌ | Cập nhật binary xong |
| `frpc_down` | Health Check | ✅ | frpc ngừng hoạt động |
| `frpc_up` | Health Check | ❌ | frpc khôi phục |
| `frpc_rate_limit` | Health Check | ✅ | Đạt giới hạn 5 restart/giờ |

### Ví dụ webhook payload

**Cài đặt thành công:**

```json
{
  "event": "install_success",
  "status": "success",
  "box_name": "Box-HaNoi-01",
  "frpc_version": "0.66.0",
  "public_ip": "123.45.67.89",
  "proxies": {
    "socks5": { "port": 51234, "username": "abc", "password": "xyz" },
    "http": { "port": 52234, "username": "abc", "password": "xyz" },
    "admin_api": { "port": 53234, "username": "admin", "password": "123" }
  },
  "frpc_running": true,
  "proxies_registered": 3
}
```

**frpc Down (có logs để debug):**

```json
{
  "event": "frpc_down",
  "message": "frpc is not responding",
  "box_name": "Box-HaNoi-01",
  "frpc_logs": "Jan 09 17:30:01 sv1 frpc: connection lost|..."
}
```

## 🏥 Health Check

| Cấu hình | Giá trị |
|----------|---------|
| Script | `/opt/frpc/healthcheck.sh` |
| Cron | Chạy mỗi **2 phút** |
| Rate limit | Tối đa **5 restarts/giờ** |
| Log | `/var/log/frpc-healthcheck.log` |
| Log rotation | **1MB**, giữ **3 backups** |

### Thêm webhook thủ công (nếu quên khi cài)

```bash
echo "https://webhook.site/your-id" > /opt/frpc/.webhook_url
```

### Xem log health check

```bash
tail -f /var/log/frpc-healthcheck.log
```

## 🖥️ Quản lý Service

```bash
systemctl status frpc      # Xem status
systemctl restart frpc     # Restart
systemctl stop frpc        # Dừng
journalctl -u frpc -f      # Xem logs realtime
cat /opt/frpc/frpc.toml    # Xem config
```

## ⚙️ Yêu cầu FRP Server

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

- `auth.token` trong frps.toml **PHẢI KHỚP** với token trong `--server`
- Nếu không khớp → frpc báo lỗi "token mismatch"
- Nếu port ngoài `allowPorts` → frpc báo lỗi "port not allowed"

## 📁 Cấu trúc thư mục

```
/opt/frpc/
├── frpc                    # Binary
├── frpc.toml               # Config
├── healthcheck.sh          # Health check script
├── .webhook_url            # Webhook URL (nếu có)
├── .frpc_down              # Flag đánh dấu đang down
└── .healthcheck_state      # Lịch sử restart timestamps

/var/log/
├── frpc-healthcheck.log    # Log hiện tại
├── frpc-healthcheck.log.1  # Backup 1
├── frpc-healthcheck.log.2  # Backup 2
└── frpc-healthcheck.log.3  # Backup 3

/etc/systemd/system/
└── frpc.service            # Systemd service
```

## 🔧 Troubleshooting

### Token mismatch

```bash
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
cat /opt/frpc/.webhook_url
# Nếu không có, thêm thủ công:
echo "https://your-webhook-url" > /opt/frpc/.webhook_url
```

### Xem logs chi tiết

```bash
# frpc logs
journalctl -u frpc -n 50

# Health check logs
tail -50 /var/log/frpc-healthcheck.log
```

## 📊 Retry Mechanisms

| Component | Attempts | Delays | Total Time |
|-----------|----------|--------|------------|
| Download | 3 | 3s each | ~10s |
| Port selection | 3 | immediate | <10s |
| Installation webhook | 5 | 20s, 40s, 80s, 160s | ~5 min |
| Health check webhook | 3 | 5s, 10s | ~30s |

## 📜 Version History

| Version | Changes |
|---------|---------|
| v3.2 | Log rotation (1MB, 3 backups) |
| v3.1 | Fix service creation order, remove wrong FRP check |
| v3.0 | Add frpc_logs to webhooks |
| v2.9 | Add frpc_logs to failed installation webhook |
| v2.8 | Port try-and-retry (max 3 attempts) |
| v2.7 | Improve webhook retry (5min install, 30s health) |
| v2.6 | Add event field to installation webhook |
| v2.5 | Health check webhook notifications |
| v2.4 | Health check cron with rate limiting |

## 📄 License

MIT
