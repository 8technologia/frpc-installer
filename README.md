# FRPC Auto-Installer

Script tự động cài đặt frpc với cấu hình ngẫu nhiên.

## Tính năng

- ✅ Tự động phát hiện kiến trúc CPU (amd64, arm64, arm)
- ✅ Tải phiên bản frpc mới nhất từ GitHub
- ✅ Random port: SOCKS5 (51xxx), HTTP (52xxx), Admin (53xxx)
- ✅ Random username/password
- ✅ Tự động cấu hình systemd (auto-start khi boot)
- ✅ Gửi thông tin về webhook (tùy chọn)

## Sử dụng

### Cài đặt cơ bản

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/frpc-installer/main/install.sh | sudo bash
```

### Với tên box tùy chọn

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/frpc-installer/main/install.sh | sudo bash -s -- --name "Box-HaNoi-01"
```

### Với webhook

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/frpc-installer/main/install.sh | sudo bash -s -- --webhook "https://webhook.site/your-id"
```

### Đầy đủ tham số

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/frpc-installer/main/install.sh | sudo bash -s -- \
  --name "Box-HaNoi-01" \
  --webhook "https://webhook.site/your-id"
```

## Kết quả sau cài đặt

Script sẽ in ra:

```
Box Name: Box-HaNoi-01
Server: 103.166.185.156:7000

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

Nếu cung cấp `--webhook`, script sẽ POST JSON:

```json
{
  "timestamp": "2026-01-09T14:54:00+07:00",
  "hostname": "armbian",
  "box_name": "Box-HaNoi-01",
  "architecture": "arm64",
  "frpc_version": "0.66.0",
  "server": "103.166.185.156:7000",
  "public_ip": "123.45.67.89",
  "proxies": {
    "socks5": {
      "port": 51234,
      "address": "103.166.185.156:51234",
      "username": "...",
      "password": "..."
    },
    "http": {
      "port": 52234,
      "address": "103.166.185.156:52234",
      "username": "...",
      "password": "..."
    },
    "admin_api": {
      "port": 53234,
      "address": "103.166.185.156:53234",
      "username": "admin",
      "password": "..."
    }
  },
  "bandwidth_limit": "8MB",
  "status": "success"
}
```

## Quản lý service

```bash
# Xem status
systemctl status frpc

# Restart
systemctl restart frpc

# Xem logs
journalctl -u frpc -f

# Stop
systemctl stop frpc
```

## Yêu cầu trên FRP Server

Đảm bảo `frps.toml` đã mở port:

```toml
allowPorts = [
  { start = 51001, end = 51999 },
  { start = 52001, end = 52999 },
  { start = 53001, end = 53999 }
]
```

## License

MIT
