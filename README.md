# FRPC Auto-Installer v2.1

Script tự động cài đặt và cấu hình frpc với random ports.

## Tính năng

- ✅ Tự động phát hiện kiến trúc CPU (amd64, arm64, arm)
- ✅ Tải phiên bản frpc mới nhất từ GitHub
- ✅ Random port: SOCKS5 (51xxx), HTTP (52xxx), Admin (53xxx)
- ✅ Random username/password
- ✅ Systemd auto-start khi boot
- ✅ Webhook với retry (5 lần, exponential backoff)
- ✅ Retry download 3 lần
- ✅ Kiểm tra network, disk space
- ✅ Update mode (chỉ cập nhật binary, giữ config)
- ✅ Uninstall mode

## Cài đặt

### Cài mới (bắt buộc `--server`)

```bash
curl -fsSL https://raw.githubusercontent.com/8technologia/frpc-installer/master/install.sh | sudo bash -s -- \
  --server "103.166.185.156:7000:your_token"
```

### Với tên box

```bash
curl -fsSL https://raw.githubusercontent.com/8technologia/frpc-installer/master/install.sh | sudo bash -s -- \
  --server "103.166.185.156:7000:your_token" \
  --name "Box-HaNoi-01"
```

### Với webhook

```bash
curl -fsSL https://raw.githubusercontent.com/8technologia/frpc-installer/master/install.sh | sudo bash -s -- \
  --server "103.166.185.156:7000:your_token" \
  --webhook "https://webhook.site/your-id"
```

### Đầy đủ tham số

```bash
curl -fsSL https://raw.githubusercontent.com/8technologia/frpc-installer/master/install.sh | sudo bash -s -- \
  --server "103.166.185.156:7000:your_token" \
  --name "Box-HaNoi-01" \
  --webhook "https://webhook.site/your-id"
```

### Cập nhật (giữ config)

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
| `--server "IP:PORT:TOKEN"` | ✅ (cài mới) | Server FRP format: IP:PORT:TOKEN |
| `--name "Box Name"` | ❌ | Tên box (mặc định: Box-hostname-xxx) |
| `--webhook "URL"` | ❌ | URL nhận thông báo sau cài đặt |
| `--update` | ❌ | Chỉ cập nhật binary, giữ config |
| `--uninstall` | ❌ | Gỡ cài đặt hoàn toàn |

## Kết quả cài đặt

```
Box Name: Box-HaNoi-01

SOCKS5 Proxy:
  Address: 103.166.185.156:51234
  Username: a8f2k9x1m3p7q4w2
  Password: z7n4b2v9c5q8r1t6

HTTP Proxy:
  Address: 103.166.185.156:52234
  Username: a8f2k9x1m3p7q4w2
  Password: z7n4b2v9c5q8r1t6

Admin API:
  Address: 103.166.185.156:53234
  Username: admin
  Password: x9m3k7p2a5b8c1d4
```

## Webhook Data

```json
{
  "timestamp": "2026-01-09T15:00:00+07:00",
  "hostname": "armbian",
  "box_name": "Box-HaNoi-01",
  "architecture": "arm64",
  "frpc_version": "0.66.0",
  "public_ip": "123.45.67.89",
  "proxies": {
    "socks5": { "port": 51234, "username": "...", "password": "..." },
    "http": { "port": 52234, "username": "...", "password": "..." },
    "admin_api": { "port": 53234, "username": "admin", "password": "..." }
  },
  "status": "success"
}
```

## Quản lý service

```bash
systemctl status frpc      # Xem status
systemctl restart frpc     # Restart
journalctl -u frpc -f      # Xem logs
```

## Yêu cầu FRP Server

```toml
# frps.toml
allowPorts = [
  { start = 51001, end = 51999 },
  { start = 52001, end = 52999 },
  { start = 53001, end = 53999 }
]
```

## License

MIT
