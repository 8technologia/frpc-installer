#!/bin/bash
#
# FRPC Auto-Installer Script
# Automatically installs and configures frpc with random ports
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/frpc-installer/main/install.sh | bash
#   curl -fsSL ... | bash -s -- --webhook "https://webhook.site/xxx"
#   curl -fsSL ... | bash -s -- --name "Box-HaNoi-01" --webhook "https://..."
#

set -e

# ============================================================
# CONFIGURATION - Fixed values
# ============================================================
SERVER_ADDR="103.166.185.156"
SERVER_PORT="7000"
AUTH_TOKEN="angimaxinhthe"
BANDWIDTH_LIMIT="8MB"
INSTALL_DIR="/opt/frpc"

# Admin API credentials (fixed)
ADMIN_USER="admin"

# ============================================================
# Parse arguments
# ============================================================
BOX_NAME=""
WEBHOOK_URL=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --name)
            BOX_NAME="$2"
            shift 2
            ;;
        --webhook)
            WEBHOOK_URL="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# ============================================================
# Helper functions
# ============================================================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

generate_password() {
    tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 16
}

get_arch() {
    local arch=$(uname -m)
    case $arch in
        x86_64)
            echo "amd64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        armv7l|armv7)
            echo "arm"
            ;;
        *)
            echo "unsupported"
            ;;
    esac
}

get_latest_version() {
    curl -s https://api.github.com/repos/fatedier/frp/releases/latest | grep '"tag_name"' | sed -E 's/.*"v([^"]+)".*/\1/'
}

# ============================================================
# Main installation
# ============================================================
log "=========================================="
log "  FRPC Auto-Installer"
log "=========================================="

# Check root
if [ "$EUID" -ne 0 ]; then
    log "ERROR: Please run as root (sudo)"
    exit 1
fi

# Detect architecture
ARCH=$(get_arch)
if [ "$ARCH" == "unsupported" ]; then
    log "ERROR: Unsupported architecture: $(uname -m)"
    exit 1
fi
log "Detected architecture: $ARCH"

# Get latest version
VERSION=$(get_latest_version)
if [ -z "$VERSION" ]; then
    VERSION="0.66.0"
    log "Could not detect latest version, using $VERSION"
else
    log "Latest frpc version: $VERSION"
fi

# Generate random port suffix (001-999)
PORT_SUFFIX=$(printf "%03d" $((RANDOM % 999 + 1)))
SOCKS5_PORT="51${PORT_SUFFIX}"
HTTP_PORT="52${PORT_SUFFIX}"
ADMIN_PORT="53${PORT_SUFFIX}"

log "Generated ports: SOCKS5=$SOCKS5_PORT, HTTP=$HTTP_PORT, Admin=$ADMIN_PORT"

# Generate credentials
PROXY_USER=$(generate_password)
PROXY_PASS=$(generate_password)
ADMIN_PASS=$(generate_password)

log "Generated credentials"

# Set box name
if [ -z "$BOX_NAME" ]; then
    BOX_NAME="Box-$(hostname)-${PORT_SUFFIX}"
fi
log "Box name: $BOX_NAME"

# Download frpc
log "Downloading frpc v$VERSION for linux_$ARCH..."
DOWNLOAD_URL="https://github.com/fatedier/frp/releases/download/v${VERSION}/frp_${VERSION}_linux_${ARCH}.tar.gz"
TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"

curl -sL "$DOWNLOAD_URL" -o frp.tar.gz
tar -xzf frp.tar.gz
cd frp_${VERSION}_linux_${ARCH}

# Install
log "Installing to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
cp frpc "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/frpc"

# Create config
log "Creating configuration..."
cat > "$INSTALL_DIR/frpc.toml" << EOF
serverAddr = "$SERVER_ADDR"
serverPort = $SERVER_PORT
loginFailExit = true

webServer.addr = "127.0.0.1"
webServer.port = 7400
webServer.user = "$ADMIN_USER"
webServer.password = "$ADMIN_PASS"

auth.method = "token"
auth.token = "$AUTH_TOKEN"

# SOCKS5 Proxy
[[proxies]]
name = "$BOX_NAME - SOCKS5"
type = "tcp"
remotePort = $SOCKS5_PORT
transport.bandwidthLimit = "$BANDWIDTH_LIMIT"

[proxies.plugin]
type = "socks5"
username = "$PROXY_USER"
password = "$PROXY_PASS"

# HTTP Proxy
[[proxies]]
name = "$BOX_NAME - HTTP"
type = "tcp"
remotePort = $HTTP_PORT
transport.bandwidthLimit = "$BANDWIDTH_LIMIT"

[proxies.plugin]
type = "http_proxy"
httpUser = "$PROXY_USER"
httpPassword = "$PROXY_PASS"

# Admin API
[[proxies]]
name = "$BOX_NAME - Admin"
type = "tcp"
localIP = "127.0.0.1"
localPort = 7400
remotePort = $ADMIN_PORT
EOF

# Create systemd service
log "Creating systemd service..."
cat > /etc/systemd/system/frpc.service << EOF
[Unit]
Description=FRP Client Service
Documentation=https://github.com/fatedier/frp
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Restart=always
RestartSec=5
ExecStart=$INSTALL_DIR/frpc -c $INSTALL_DIR/frpc.toml
ExecReload=/bin/kill -HUP \$MAINPID
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

# Enable and start service
log "Enabling and starting frpc service..."
systemctl daemon-reload
systemctl enable frpc
systemctl start frpc

# Wait for service to start
sleep 3

# Check status
if systemctl is-active --quiet frpc; then
    STATUS="success"
    log "frpc is running!"
else
    STATUS="failed"
    log "ERROR: frpc failed to start"
    journalctl -u frpc -n 20 --no-pager
fi

# Cleanup
rm -rf "$TMP_DIR"

# Get public IP
PUBLIC_IP=$(curl -s https://api.ipify.org 2>/dev/null || echo "unknown")

# Print summary
log "=========================================="
log "  INSTALLATION COMPLETE"
log "=========================================="
echo ""
echo "Box Name: $BOX_NAME"
echo "Server: $SERVER_ADDR:$SERVER_PORT"
echo ""
echo "SOCKS5 Proxy:"
echo "  Address: $SERVER_ADDR:$SOCKS5_PORT"
echo "  Username: $PROXY_USER"
echo "  Password: $PROXY_PASS"
echo ""
echo "HTTP Proxy:"
echo "  Address: $SERVER_ADDR:$HTTP_PORT"
echo "  Username: $PROXY_USER"
echo "  Password: $PROXY_PASS"
echo ""
echo "Admin API:"
echo "  Address: $SERVER_ADDR:$ADMIN_PORT"
echo "  Username: $ADMIN_USER"
echo "  Password: $ADMIN_PASS"
echo ""
echo "Public IP: $PUBLIC_IP"
echo ""

# Send to webhook if provided
if [ -n "$WEBHOOK_URL" ]; then
    log "Sending data to webhook..."
    
    TIMESTAMP=$(date -Iseconds)
    JSON_DATA=$(cat << EOF
{
  "timestamp": "$TIMESTAMP",
  "hostname": "$(hostname)",
  "box_name": "$BOX_NAME",
  "architecture": "$ARCH",
  "frpc_version": "$VERSION",
  "server": "$SERVER_ADDR:$SERVER_PORT",
  "public_ip": "$PUBLIC_IP",
  "proxies": {
    "socks5": {
      "port": $SOCKS5_PORT,
      "address": "$SERVER_ADDR:$SOCKS5_PORT",
      "username": "$PROXY_USER",
      "password": "$PROXY_PASS"
    },
    "http": {
      "port": $HTTP_PORT,
      "address": "$SERVER_ADDR:$HTTP_PORT",
      "username": "$PROXY_USER",
      "password": "$PROXY_PASS"
    },
    "admin_api": {
      "port": $ADMIN_PORT,
      "address": "$SERVER_ADDR:$ADMIN_PORT",
      "username": "$ADMIN_USER",
      "password": "$ADMIN_PASS"
    }
  },
  "bandwidth_limit": "$BANDWIDTH_LIMIT",
  "status": "$STATUS"
}
EOF
)
    
    curl -s -X POST "$WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "$JSON_DATA" > /dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        log "Webhook sent successfully!"
    else
        log "Warning: Failed to send webhook"
    fi
fi

log "Done!"
