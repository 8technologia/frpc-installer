# FRPC Auto-Installer

Script tự động cài đặt frpc với cấu hình ngẫu nhiên.

## Tính năng

- ✅ Tự động phát hiện kiến trúc CPU (amd64, arm64, arm)
- ✅ Tải phiên bản frpc mới nhất từ GitHub
- ✅ Random port: SOCKS5 (51xxx), HTTP (52xxx), Admin (53xxx)
- ✅ Random username/password
- ✅ Tự động cấu hình systemd (auto-start khi boot)
- ✅ Gửi thông tin về webhook (tùy chọn)
- ✅ Retry download 3 lần nếu thất bại
- ✅ Kiểm tra network, disk space
- ✅ Hỗ trợ update và uninstall

## Cài đặt

### Cài mới

```bash
curl -fsSL https://raw.githubusercontent.com/8technologia/frpc-installer/master/install.sh | sudo bash
```

### Với tên box

```bash
curl -fsSL https://raw.githubusercontent.com/8technologia/frpc-installer/master/install.sh | sudo bash -s -- --name "Box-HaNoi-01"
```

### Với webhook

```bash
curl -fsSL https://raw.githubusercontent.com/8technologia/frpc-installer/master/install.sh | sudo bash -s -- --webhook "https://webhook.site/your-id"
```

### Đầy đủ tham số

```bash
curl -fsSL https://raw.githubusercontent.com/8technologia/frpc-installer/master/install.sh | sudo bash -s -- \
  --name "Box-HaNoi-01" \
  --webhook "https://webhook.site/your-id"
```

### Cập nhật

```bash
curl -fsSL https://raw.githubusercontent.com/8technologia/frpc-installer/master/install.sh | sudo bash -s -- --update
```

### Gỡ cài đặt

```bash
curl -fsSL https://raw.githubusercontent.com/8technologia/frpc-installer/master/install.sh | sudo bash -s -- --uninstall
```

## Kết quả sau cài đặt

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

## Quản lý service

```bash
systemctl status frpc      # Xem status
systemctl restart frpc     # Restart
journalctl -u frpc -f      # Xem logs
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
