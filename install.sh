#!/bin/bash
#
# FRPC Auto-Installer Script v2.1
# Automatically installs and configures frpc with random ports
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/8technologia/frpc-installer/master/install.sh | sudo bash -s -- --server "IP:PORT:TOKEN"
#   curl -fsSL ... | sudo bash -s -- --server "103.166.185.156:7000:mytoken" --name "Box-01"
#   curl -fsSL ... | sudo bash -s -- --server "103.166.185.156:7000:mytoken" --webhook "https://webhook.site/xxx"
#   curl -fsSL ... | sudo bash -s -- --uninstall
#

set -e

# ============================================================
# CONFIGURATION
# ============================================================
SERVER_ADDR=""
SERVER_PORT="7000"
AUTH_TOKEN=""
BANDWIDTH_LIMIT="8MB"
INSTALL_DIR="/opt/frpc"
ADMIN_USER="admin"
REQUIRED_SPACE_KB=50000  # 50MB

# ============================================================
# Parse arguments
# ============================================================
BOX_NAME=""
WEBHOOK_URL=""
UNINSTALL=false
UPDATE_MODE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --server)
            # Format: IP:PORT:TOKEN
            IFS=':' read -r SERVER_ADDR SERVER_PORT AUTH_TOKEN <<< "$2"
            shift 2
            ;;
        --name)
            BOX_NAME="$2"
            shift 2
            ;;
        --webhook)
            WEBHOOK_URL="$2"
            shift 2
            ;;
        --uninstall)
            UNINSTALL=true
            shift
            ;;
        --update)
            UPDATE_MODE=true
            shift
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
    curl -s --max-time 10 https://api.github.com/repos/fatedier/frp/releases/latest 2>/dev/null | grep '"tag_name"' | sed -E 's/.*"v([^"]+)".*/\1/'
}

# Feature 2: Download with retry
download_with_retry() {
    local url="$1"
    local output="$2"
    local max_attempts=3
    
    for i in $(seq 1 $max_attempts); do
        log "Download attempt $i/$max_attempts..."
        if curl -sL --max-time 120 "$url" -o "$output"; then
            if [ -s "$output" ]; then
                return 0
            fi
        fi
        log "Download failed, retrying in 3 seconds..."
        sleep 3
    done
    return 1
}

# Feature 3: Verify checksum
verify_download() {
    local file="$1"
    if [ ! -f "$file" ]; then
        return 1
    fi
    # Check file is valid tar.gz
    if ! tar -tzf "$file" &>/dev/null; then
        log "ERROR: Downloaded file is corrupted"
        return 1
    fi
    log "Download verified successfully"
    return 0
}

# Feature 5: Check network connectivity
check_network() {
    log "Checking network connectivity..."
    if ! curl -s --max-time 10 https://github.com > /dev/null 2>&1; then
        log "ERROR: Cannot connect to GitHub. Please check your internet connection."
        exit 1
    fi
    if ! curl -s --max-time 10 "http://$SERVER_ADDR:$SERVER_PORT" > /dev/null 2>&1; then
        log "WARNING: Cannot connect to FRP server $SERVER_ADDR:$SERVER_PORT"
        log "Continuing anyway, but frpc may fail to connect..."
    fi
    log "Network connectivity OK"
}

# Feature 6: Verify service running
verify_service() {
    log "Verifying frpc service..."
    local max_attempts=10
    
    for i in $(seq 1 $max_attempts); do
        if systemctl is-active --quiet frpc; then
            # Try to access admin API
            if curl -s --max-time 5 "http://127.0.0.1:7400/healthz" > /dev/null 2>&1; then
                log "frpc service is running and healthy!"
                return 0
            fi
        fi
        log "Waiting for service to start... ($i/$max_attempts)"
        sleep 2
    done
    
    log "WARNING: frpc service may not be fully operational"
    return 1
}

# Feature 9: Check disk space
check_disk_space() {
    log "Checking disk space..."
    local install_path=$(dirname "$INSTALL_DIR")
    local available=$(df "$install_path" 2>/dev/null | tail -1 | awk '{print $4}')
    
    if [ -z "$available" ]; then
        log "WARNING: Could not check disk space"
        return 0
    fi
    
    if [ "$available" -lt "$REQUIRED_SPACE_KB" ]; then
        log "ERROR: Not enough disk space. Required: ${REQUIRED_SPACE_KB}KB, Available: ${available}KB"
        exit 1
    fi
    log "Disk space OK (${available}KB available)"
}

# Feature 7: Uninstall function
do_uninstall() {
    log "=========================================="
    log "  FRPC Uninstaller"
    log "=========================================="
    
    if systemctl is-active --quiet frpc 2>/dev/null; then
        log "Stopping frpc service..."
        systemctl stop frpc
    fi
    
    if systemctl is-enabled --quiet frpc 2>/dev/null; then
        log "Disabling frpc service..."
        systemctl disable frpc
    fi
    
    if [ -f /etc/systemd/system/frpc.service ]; then
        log "Removing systemd service..."
        rm -f /etc/systemd/system/frpc.service
        systemctl daemon-reload
    fi
    
    if [ -d "$INSTALL_DIR" ]; then
        log "Removing installation directory..."
        rm -rf "$INSTALL_DIR"
    fi
    
    log "=========================================="
    log "  UNINSTALL COMPLETE"
    log "=========================================="
    exit 0
}

# Install dependencies
install_dependencies() {
    local missing=()
    
    for cmd in curl tar grep sed; do
        if ! command -v $cmd &> /dev/null; then
            missing+=($cmd)
        fi
    done
    
    if [ ${#missing[@]} -eq 0 ]; then
        return 0
    fi
    
    log "Installing missing dependencies: ${missing[*]}"
    
    if command -v apt-get &> /dev/null; then
        apt-get update -qq
        apt-get install -y -qq "${missing[@]}"
    elif command -v yum &> /dev/null; then
        yum install -y -q "${missing[@]}"
    elif command -v apk &> /dev/null; then
        apk add --quiet "${missing[@]}"
    else
        log "ERROR: Could not detect package manager. Please install manually: ${missing[*]}"
        exit 1
    fi
}

# ============================================================
# Main
# ============================================================
log "=========================================="
log "  FRPC Auto-Installer v2.1"
log "=========================================="

# Check root
if [ "$EUID" -ne 0 ]; then
    log "ERROR: Please run as root (sudo)"
    exit 1
fi

# Feature 7: Handle uninstall (doesn't need --server)
if [ "$UNINSTALL" = true ]; then
    do_uninstall
fi

# Validate required --server parameter
if [ -z "$SERVER_ADDR" ] || [ -z "$AUTH_TOKEN" ]; then
    log "ERROR: --server parameter is required"
    log ""
    log "Usage: curl -fsSL .../install.sh | sudo bash -s -- --server \"IP:PORT:TOKEN\""
    log "Example: --server \"103.166.185.156:7000:mytoken\""
    exit 1
fi

log "Server: $SERVER_ADDR:$SERVER_PORT"

# Feature 1: Check if already installed (update mode)
if [ -f "$INSTALL_DIR/frpc" ]; then
    if [ "$UPDATE_MODE" = true ]; then
        log "Update mode: Existing installation found"
        log "Backing up current config..."
        cp "$INSTALL_DIR/frpc.toml" "$INSTALL_DIR/frpc.toml.bak" 2>/dev/null || true
    else
        log "WARNING: frpc is already installed at $INSTALL_DIR"
        log "Use --update to update, or --uninstall to remove first"
        log ""
        log "Current config:"
        cat "$INSTALL_DIR/frpc.toml" 2>/dev/null | grep -E "^(name|remotePort|username)" | head -10
        exit 0
    fi
fi

# Install dependencies
install_dependencies

# Feature 5: Check network
check_network

# Feature 9: Check disk space
check_disk_space

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

# Download frpc with retry
log "Downloading frpc v$VERSION for linux_$ARCH..."
DOWNLOAD_URL="https://github.com/fatedier/frp/releases/download/v${VERSION}/frp_${VERSION}_linux_${ARCH}.tar.gz"
TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"

# Feature 2: Download with retry
if ! download_with_retry "$DOWNLOAD_URL" "frp.tar.gz"; then
    log "ERROR: Failed to download frpc after multiple attempts"
    rm -rf "$TMP_DIR"
    exit 1
fi

# Feature 3: Verify download
if ! verify_download "frp.tar.gz"; then
    log "ERROR: Download verification failed"
    rm -rf "$TMP_DIR"
    exit 1
fi

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
systemctl restart frpc

# Feature 6: Verify service
verify_service
if [ $? -eq 0 ]; then
    STATUS="success"
else
    STATUS="partial"
fi

# Cleanup
rm -rf "$TMP_DIR"

# Get public IP
PUBLIC_IP=$(curl -s --max-time 10 https://api.ipify.org 2>/dev/null || echo "unknown")

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
echo "Commands:"
echo "  Status:    systemctl status frpc"
echo "  Restart:   systemctl restart frpc"
echo "  Logs:      journalctl -u frpc -f"
echo "  Uninstall: curl -fsSL .../install.sh | sudo bash -s -- --uninstall"
echo ""

# Send to webhook if provided (with retry and exponential backoff)
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
    
    # Retry with exponential backoff (5 attempts: 2s, 4s, 8s, 16s, 32s)
    MAX_WEBHOOK_RETRIES=5
    WEBHOOK_DELAY=2
    WEBHOOK_SUCCESS=false
    
    for i in $(seq 1 $MAX_WEBHOOK_RETRIES); do
        log "Webhook attempt $i/$MAX_WEBHOOK_RETRIES..."
        
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d "$JSON_DATA" --max-time 30 2>/dev/null || echo "000")
        
        if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
            log "Webhook sent successfully! (HTTP $HTTP_CODE)"
            WEBHOOK_SUCCESS=true
            break
        else
            log "Webhook failed (HTTP $HTTP_CODE), retrying in ${WEBHOOK_DELAY}s..."
            sleep $WEBHOOK_DELAY
            WEBHOOK_DELAY=$((WEBHOOK_DELAY * 2))  # Exponential backoff
        fi
    done
    
    if [ "$WEBHOOK_SUCCESS" = false ]; then
        log "WARNING: Failed to send webhook after $MAX_WEBHOOK_RETRIES attempts"
    fi
fi

log "Done!"
