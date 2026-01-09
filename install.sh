#!/bin/bash
#
# FRPC Auto-Installer Script v3.2
# Automatically installs and configures frpc with random ports
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
            SERVER_ADDR=$(echo "$2" | cut -d':' -f1)
            SERVER_PORT=$(echo "$2" | cut -d':' -f2)
            AUTH_TOKEN=$(echo "$2" | cut -d':' -f3-)
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

# Generate random ports (returns suffix)
generate_ports() {
    PORT_SUFFIX=$(printf "%03d" $((RANDOM % 999 + 1)))
    SOCKS5_PORT="51${PORT_SUFFIX}"
    HTTP_PORT="52${PORT_SUFFIX}"
    ADMIN_PORT="53${PORT_SUFFIX}"
    log "Generated ports: SOCKS5=$SOCKS5_PORT, HTTP=$HTTP_PORT, Admin=$ADMIN_PORT"
}

# Create frpc config file
create_config() {
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
}

# Check if frpc started successfully (for port retry)
check_frpc_started() {
    sleep 3
    if ! systemctl is-active --quiet frpc; then
        return 1
    fi
    
    # Check for port error in recent logs
    local recent_log=$(journalctl -u frpc -n 5 --no-pager 2>/dev/null)
    if echo "$recent_log" | grep -qiE "port.*already|port.*used|port not allowed"; then
        return 2  # Port conflict
    fi
    
    if echo "$recent_log" | grep -qi "token"; then
        return 3  # Token error
    fi
    
    return 0
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

# Feature 5: Check network connectivity (GitHub only, FRP uses different protocol)
check_network() {
    log "Checking network connectivity..."
    if ! curl -s --max-time 10 https://github.com > /dev/null 2>&1; then
        log "ERROR: Cannot connect to GitHub. Please check your internet connection."
        exit 1
    fi
    log "Network connectivity OK"
}

# Feature 6: Verify service running with detailed status
verify_service() {
    log "Verifying frpc service..."
    local max_attempts=15
    
    ERROR_MESSAGE=""
    PROXIES_RUNNING=0
    FRPC_RUNNING=false
    
    for i in $(seq 1 $max_attempts); do
        if systemctl is-active --quiet frpc; then
            FRPC_RUNNING=true
            
            # Check admin API with auth
            local status_response=$(curl -s --max-time 5 -u "$ADMIN_USER:$ADMIN_PASS" "http://127.0.0.1:7400/api/status" 2>/dev/null)
            
            if [ -n "$status_response" ] && echo "$status_response" | grep -q "status"; then
                # Count running proxies
                PROXIES_RUNNING=$(echo "$status_response" | grep -oE '"status"\s*:\s*"running"' | wc -l)
                
                if [ "$PROXIES_RUNNING" -ge 3 ]; then
                    log "frpc service is running! $PROXIES_RUNNING proxies registered."
                    return 0
                elif [ "$PROXIES_RUNNING" -ge 1 ]; then
                    log "Proxies connecting... ($PROXIES_RUNNING/3 running)"
                fi
            fi
        fi
        
        log "Waiting for service to stabilize... ($i/$max_attempts)"
        sleep 2
    done
    
    # If we get here, service is not fully operational
    # Get error from journal
    ERROR_MESSAGE=$(journalctl -u frpc -n 10 --no-pager 2>/dev/null | grep -iE "error|failed|token|port" | tail -3 | tr '\n' ' ')
    
    if [ -z "$ERROR_MESSAGE" ]; then
        ERROR_MESSAGE="Service not responding after $max_attempts attempts"
    fi
    
    log "WARNING: frpc service may not be fully operational"
    log "Error: $ERROR_MESSAGE"
    return 1
}

# Retry frpc service with troubleshooting
retry_frpc_service() {
    local max_retries=3
    log "Attempting to recover frpc service..."
    
    for i in $(seq 1 $max_retries); do
        log "Retry attempt $i/$max_retries..."
        
        # Restart service
        systemctl restart frpc
        sleep 5
        
        # Verify
        if verify_service; then
            log "Recovery successful on attempt $i!"
            return 0
        fi
        
        # If token error, can't retry
        if echo "$ERROR_MESSAGE" | grep -qi "token"; then
            log "ERROR: Token mismatch detected. Please check auth.token in config."
            return 1
        fi
        
        # If port error, can't retry
        if echo "$ERROR_MESSAGE" | grep -qi "port not allowed\|port already"; then
            log "ERROR: Port issue detected. Check frps allowPorts configuration."
            return 1
        fi
        
        sleep 3
    done
    
    log "ERROR: Failed to recover frpc service after $max_retries attempts"
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
log "========================"
log "  FRPC Auto-Installer"
log "========================"

# Check root
if [ "$EUID" -ne 0 ]; then
    log "ERROR: Please run as root (sudo)"
    exit 1
fi

# Feature 7: Handle uninstall (doesn't need --server)
if [ "$UNINSTALL" = true ]; then
    do_uninstall
fi

# Feature: Update mode - only update binary, keep config
if [ "$UPDATE_MODE" = true ]; then
    if [ ! -f "$INSTALL_DIR/frpc" ] || [ ! -f "$INSTALL_DIR/frpc.toml" ]; then
        log "ERROR: frpc is not installed. Cannot update."
        log "Use --server parameter to install first."
        exit 1
    fi
    
    log "Update mode: Updating frpc binary only..."
    log "Existing config will be preserved."
    
    # Read server info from existing config for status display
    SERVER_ADDR=$(grep "serverAddr" "$INSTALL_DIR/frpc.toml" | head -1 | cut -d'"' -f2)
    SERVER_PORT=$(grep "serverPort" "$INSTALL_DIR/frpc.toml" | head -1 | awk '{print $3}')
    
    # Skip to binary download (set flag)
    SKIP_CONFIG_GENERATION=true
else
    SKIP_CONFIG_GENERATION=false
    
    # Validate required --server parameter (only for fresh install)
    if [ -z "$SERVER_ADDR" ] || [ -z "$AUTH_TOKEN" ]; then
        log "ERROR: --server parameter is required"
        log ""
        log "Usage: curl -fsSL .../install.sh | sudo bash -s -- --server \"IP:PORT:TOKEN\""
        log "Example: --server \"103.166.185.156:7000:mytoken\""
        log ""
        log "For update: curl -fsSL .../install.sh | sudo bash -s -- --update"
        exit 1
    fi
    
    log "Server: $SERVER_ADDR:$SERVER_PORT"
    
    # Check if already installed
    if [ -f "$INSTALL_DIR/frpc" ]; then
        log "WARNING: frpc is already installed at $INSTALL_DIR"
        log "Use --update to update binary, or --uninstall to remove first"
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

# Install binary
log "Installing to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
cp frpc "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/frpc"

# Create systemd service first (so port retry can use it)
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

# Generate config only for fresh install (skip in update mode)
if [ "$SKIP_CONFIG_GENERATION" = false ]; then
    # Generate credentials (only once)
    PROXY_USER=$(generate_password)
    PROXY_PASS=$(generate_password)
    ADMIN_PASS=$(generate_password)
    log "Generated credentials"

    # Set box name base (will add port suffix later if not provided)
    BOX_NAME_BASE="$BOX_NAME"
    
    # Port retry loop (max 3 attempts)
    MAX_PORT_RETRIES=3
    PORT_RETRY_SUCCESS=false
    
    for port_attempt in $(seq 1 $MAX_PORT_RETRIES); do
        # Generate random ports
        generate_ports
        
        # Set box name with port suffix if not provided
        if [ -z "$BOX_NAME_BASE" ]; then
            BOX_NAME="Box-$(hostname)-${PORT_SUFFIX}"
        else
            BOX_NAME="$BOX_NAME_BASE"
        fi
        log "Box name: $BOX_NAME (port attempt $port_attempt/$MAX_PORT_RETRIES)"
        
        # Create config
        log "Creating configuration..."
        create_config
        
        # Start service and check
        log "Starting frpc to test ports..."
        systemctl daemon-reload
        systemctl restart frpc
        
        check_frpc_started
        START_RESULT=$?
        
        if [ "$START_RESULT" -eq 0 ]; then
            log "Ports verified successfully!"
            PORT_RETRY_SUCCESS=true
            break
        elif [ "$START_RESULT" -eq 2 ]; then
            # Port conflict - retry with new ports
            log "Port conflict detected! Regenerating ports..."
            systemctl stop frpc 2>/dev/null
            sleep 1
        elif [ "$START_RESULT" -eq 3 ]; then
            # Token error - can't retry
            log "ERROR: Token mismatch. Check your --server token."
            break
        else
            # Other error
            log "WARNING: frpc failed to start (unknown error)"
            break
        fi
    done
    
    if [ "$PORT_RETRY_SUCCESS" = false ]; then
        log "WARNING: Could not find available ports after $MAX_PORT_RETRIES attempts"
    fi
else
    log "Keeping existing configuration..."
fi

# Create health check script with rate limiting and webhook
log "Creating health check script..."
cat > "$INSTALL_DIR/healthcheck.sh" << 'HEALTHCHECK_EOF'
#!/bin/bash
# frpc Health Check Script
# Runs via cron, restarts frpc if down
# Has rate limiting to prevent infinite restart loops
# Sends webhook notifications on down/up events

INSTALL_DIR="/opt/frpc"
LOG_FILE="/var/log/frpc-healthcheck.log"
STATE_FILE="$INSTALL_DIR/.healthcheck_state"
WEBHOOK_FILE="$INSTALL_DIR/.webhook_url"
DOWN_FLAG="$INSTALL_DIR/.frpc_down"
MAX_RESTARTS_PER_HOUR=5
MAX_LOG_SIZE=1048576  # 1MB
MAX_LOG_BACKUPS=3

rotate_log() {
    if [ -f "$LOG_FILE" ]; then
        local size=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$size" -gt "$MAX_LOG_SIZE" ]; then
            for i in $(seq $((MAX_LOG_BACKUPS-1)) -1 1); do
                [ -f "${LOG_FILE}.$i" ] && mv "${LOG_FILE}.$i" "${LOG_FILE}.$((i+1))"
            done
            mv "$LOG_FILE" "${LOG_FILE}.1"
            touch "$LOG_FILE"
        fi
    fi
}

log() {
    rotate_log
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Send webhook notification
send_webhook() {
    local event="$1"
    local message="$2"
    
    if [ ! -f "$WEBHOOK_FILE" ]; then
        return
    fi
    
    local webhook_url=$(cat "$WEBHOOK_FILE")
    if [ -z "$webhook_url" ]; then
        return
    fi
    
    local hostname=$(hostname)
    local public_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "unknown")
    local timestamp=$(date -Iseconds)
    
    # Read box name from config
    local box_name=$(grep -oP 'name = "\K[^"]+' "$INSTALL_DIR/frpc.toml" 2>/dev/null | head -1 | sed 's/ - SOCKS5//')
    
    local json_data=$(cat << EOF
{
  "event": "$event",
  "message": "$message",
  "timestamp": "$timestamp",
  "hostname": "$hostname",
  "box_name": "$box_name",
  "public_ip": "$public_ip"
}
EOF
)
    
    # Retry webhook (3 attempts: 5s, 10s delays = ~30s max)
    local max_retries=3
    local delay=5
    
    for i in $(seq 1 $max_retries); do
        local http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$webhook_url" \
            -H "Content-Type: application/json" \
            -d "$json_data" --max-time 10 2>/dev/null || echo "000")
        
        if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
            log "Webhook sent: $event - $message (HTTP $http_code)"
            return 0
        fi
        
        if [ "$i" -lt "$max_retries" ]; then
            sleep $delay
            delay=$((delay * 2))
        fi
    done
    
    log "WARNING: Failed to send webhook after $max_retries attempts"
}

# Get restart count in last hour
get_restart_count() {
    if [ ! -f "$STATE_FILE" ]; then
        echo "0"
        return
    fi
    
    local one_hour_ago=$(date -d '1 hour ago' +%s 2>/dev/null || date -v-1H +%s 2>/dev/null)
    local count=0
    
    while read timestamp; do
        if [ "$timestamp" -gt "$one_hour_ago" ] 2>/dev/null; then
            count=$((count + 1))
        fi
    done < "$STATE_FILE"
    
    echo "$count"
}

# Record restart
record_restart() {
    if [ -f "$STATE_FILE" ]; then
        tail -9 "$STATE_FILE" > "${STATE_FILE}.tmp"
        mv "${STATE_FILE}.tmp" "$STATE_FILE"
    fi
    date +%s >> "$STATE_FILE"
}

# Check if frpc is running and healthy
check_frpc() {
    if ! systemctl is-active --quiet frpc; then
        return 1
    fi
    
    local status=$(curl -s --max-time 5 "http://127.0.0.1:7400/api/status" 2>/dev/null)
    if [ -z "$status" ]; then
        return 1
    fi
    
    local running=$(echo "$status" | grep -c '"status":"running"' 2>/dev/null || echo "0")
    if [ "$running" -lt 1 ]; then
        return 1
    fi
    
    return 0
}

# Main
if check_frpc; then
    # frpc is running, check if it was previously down
    if [ -f "$DOWN_FLAG" ]; then
        rm -f "$DOWN_FLAG"
        log "frpc is back online!"
        send_webhook "frpc_up" "frpc recovered and is back online"
    fi
    exit 0
fi

# frpc is down
if [ ! -f "$DOWN_FLAG" ]; then
    # First time detecting down
    touch "$DOWN_FLAG"
    log "frpc is DOWN!"
    send_webhook "frpc_down" "frpc is not responding"
fi

# Check rate limit
RESTART_COUNT=$(get_restart_count)

if [ "$RESTART_COUNT" -ge "$MAX_RESTARTS_PER_HOUR" ]; then
    log "ERROR: Rate limit reached ($RESTART_COUNT restarts in last hour). Manual intervention required."
    send_webhook "frpc_rate_limit" "Rate limit reached ($RESTART_COUNT restarts/hour). Manual intervention required."
    exit 1
fi

# Restart frpc
log "Restarting frpc... (attempt $((RESTART_COUNT + 1))/$MAX_RESTARTS_PER_HOUR this hour)"
systemctl restart frpc
record_restart

# Wait and verify
sleep 5
if check_frpc; then
    rm -f "$DOWN_FLAG"
    log "frpc restarted successfully"
    send_webhook "frpc_up" "frpc restarted successfully"
else
    log "WARNING: frpc may not be fully operational after restart"
fi
HEALTHCHECK_EOF

chmod +x "$INSTALL_DIR/healthcheck.sh"

# Save webhook URL if provided
if [ -n "$WEBHOOK_URL" ]; then
    echo "$WEBHOOK_URL" > "$INSTALL_DIR/.webhook_url"
    log "Webhook URL saved for health check notifications"
fi

# Setup cron job (every 2 minutes)
log "Setting up health check cron job..."
CRON_LINE="*/2 * * * * $INSTALL_DIR/healthcheck.sh"

# Remove existing frpc healthcheck cron if exists
crontab -l 2>/dev/null | grep -v "frpc.*healthcheck" > /tmp/crontab_tmp
echo "$CRON_LINE" >> /tmp/crontab_tmp
crontab /tmp/crontab_tmp
rm /tmp/crontab_tmp

log "Health check cron job installed (runs every 2 minutes)"

# Enable service (start only if not already running from port retry)
log "Enabling frpc service..."
systemctl daemon-reload
systemctl enable frpc

# For fresh install: service already started in port retry loop
# For update mode: need to restart
if [ "$SKIP_CONFIG_GENERATION" = true ]; then
    log "Restarting frpc service..."
    systemctl restart frpc
fi

# Wait and verify
sleep 2

# Feature 6: Verify service with detailed status
if verify_service; then
    STATUS="success"
else
    # Try recovery
    log "Initial verification failed. Attempting recovery..."
    if retry_frpc_service; then
        STATUS="recovered"
    else
        STATUS="failed"
    fi
fi

# Cleanup temp files
rm -rf "$TMP_DIR"

# Get public IP
PUBLIC_IP=$(curl -s --max-time 10 https://api.ipify.org 2>/dev/null || echo "unknown")

# Print summary
log "=========================================="
if [ "$STATUS" = "success" ] || [ "$STATUS" = "recovered" ]; then
    log "  INSTALLATION COMPLETE"
else
    log "  INSTALLATION COMPLETE (WITH ERRORS)"
fi
log "=========================================="
echo ""
echo "Box Name: $BOX_NAME"
echo "Server: $SERVER_ADDR:$SERVER_PORT"
echo "Status: $STATUS"
echo "Proxies Running: $PROXIES_RUNNING"
echo ""

if [ "$SKIP_CONFIG_GENERATION" = false ]; then
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
fi

echo "Public IP: $PUBLIC_IP"
echo ""
echo "Commands:"
echo "  Status:    systemctl status frpc"
echo "  Restart:   systemctl restart frpc"
echo "  Logs:      journalctl -u frpc -f"
echo "  Config:    cat $INSTALL_DIR/frpc.toml"
echo "  Uninstall: curl -fsSL .../install.sh | sudo bash -s -- --uninstall"
echo ""

# Show troubleshooting if failed
if [ "$STATUS" = "failed" ]; then
    echo "=========================================="
    echo "  TROUBLESHOOTING"
    echo "=========================================="
    echo ""
    echo "Error: $ERROR_MESSAGE"
    echo ""
    echo "Common fixes:"
    echo "1. Token mismatch:"
    echo "   - Check auth.token in $INSTALL_DIR/frpc.toml"
    echo "   - Ensure it matches token in frps.toml on server"
    echo ""
    echo "2. Port not allowed:"
    echo "   - Add ports to frps.toml: allowPorts = [{start=51001,end=53999}]"
    echo "   - Run: systemctl restart frps"
    echo ""
    echo "3. Network issue:"
    echo "   - Check: curl http://$SERVER_ADDR:$SERVER_PORT"
    echo "   - Ensure firewall allows connection"
    echo ""
    echo "After fixing, restart: systemctl restart frpc"
    echo ""
fi

# Send to webhook if provided (with retry and exponential backoff)
if [ -n "$WEBHOOK_URL" ]; then
    log "Sending data to webhook..."
    
    # Escape error message for JSON
    ESCAPED_ERROR=$(echo "$ERROR_MESSAGE" | sed 's/"/\\"/g' | tr '\n' ' ')
    
    TIMESTAMP=$(date -Iseconds)
    
    # Build JSON with proper handling of update mode
    if [ "$SKIP_CONFIG_GENERATION" = true ]; then
        # Update mode - read existing values from config
        SOCKS5_PORT=$(grep -oP 'remotePort = \K[0-9]+' "$INSTALL_DIR/frpc.toml" | head -1)
        HTTP_PORT=$(grep -oP 'remotePort = \K[0-9]+' "$INSTALL_DIR/frpc.toml" | head -2 | tail -1)
        ADMIN_PORT=$(grep -oP 'remotePort = \K[0-9]+' "$INSTALL_DIR/frpc.toml" | tail -1)
        PROXY_USER="(existing)"
        PROXY_PASS="(existing)"
        ADMIN_PASS="(existing)"
        BOX_NAME=$(grep -oP 'name = "\K[^"]+' "$INSTALL_DIR/frpc.toml" | head -1 | sed 's/ - SOCKS5//')
    fi
    
    # Determine event type
    if [ "$SKIP_CONFIG_GENERATION" = true ]; then
        WEBHOOK_EVENT="update_complete"
    elif [ "$STATUS" = "failed" ]; then
        WEBHOOK_EVENT="install_failed"
    else
        WEBHOOK_EVENT="install_success"
    fi
    
    JSON_DATA=$(cat << EOF
{
  "event": "$WEBHOOK_EVENT",
  "timestamp": "$TIMESTAMP",
  "hostname": "$(hostname)",
  "box_name": "$BOX_NAME",
  "architecture": "$ARCH",
  "frpc_version": "$VERSION",
  "server": "$SERVER_ADDR:$SERVER_PORT",
  "public_ip": "$PUBLIC_IP",
  "proxies": {
    "socks5": {
      "port": ${SOCKS5_PORT:-0},
      "address": "$SERVER_ADDR:${SOCKS5_PORT:-0}",
      "username": "$PROXY_USER",
      "password": "$PROXY_PASS"
    },
    "http": {
      "port": ${HTTP_PORT:-0},
      "address": "$SERVER_ADDR:${HTTP_PORT:-0}",
      "username": "$PROXY_USER",
      "password": "$PROXY_PASS"
    },
    "admin_api": {
      "port": ${ADMIN_PORT:-0},
      "address": "$SERVER_ADDR:${ADMIN_PORT:-0}",
      "username": "$ADMIN_USER",
      "password": "$ADMIN_PASS"
    }
  },
  "bandwidth_limit": "$BANDWIDTH_LIMIT",
  "status": "$STATUS",
  "frpc_running": $FRPC_RUNNING,
  "proxies_registered": $PROXIES_RUNNING,
  "error": "$ESCAPED_ERROR",
  "frpc_logs": "$FRPC_LOGS"
}
EOF
)
    
    # Get frpc logs if failed (for debugging)
    if [ "$STATUS" = "failed" ]; then
        FRPC_LOGS=$(journalctl -u frpc -n 20 --no-pager 2>/dev/null | sed 's/"/\\"/g' | tr '\n' '|')
        # Re-build JSON with logs
        JSON_DATA=$(cat << EOF
{
  "event": "$WEBHOOK_EVENT",
  "timestamp": "$TIMESTAMP",
  "hostname": "$(hostname)",
  "box_name": "$BOX_NAME",
  "architecture": "$ARCH",
  "frpc_version": "$VERSION",
  "server": "$SERVER_ADDR:$SERVER_PORT",
  "public_ip": "$PUBLIC_IP",
  "proxies": {
    "socks5": {
      "port": ${SOCKS5_PORT:-0},
      "address": "$SERVER_ADDR:${SOCKS5_PORT:-0}",
      "username": "$PROXY_USER",
      "password": "$PROXY_PASS"
    },
    "http": {
      "port": ${HTTP_PORT:-0},
      "address": "$SERVER_ADDR:${HTTP_PORT:-0}",
      "username": "$PROXY_USER",
      "password": "$PROXY_PASS"
    },
    "admin_api": {
      "port": ${ADMIN_PORT:-0},
      "address": "$SERVER_ADDR:${ADMIN_PORT:-0}",
      "username": "$ADMIN_USER",
      "password": "$ADMIN_PASS"
    }
  },
  "bandwidth_limit": "$BANDWIDTH_LIMIT",
  "status": "$STATUS",
  "frpc_running": $FRPC_RUNNING,
  "proxies_registered": $PROXIES_RUNNING,
  "error": "$ESCAPED_ERROR",
  "frpc_logs": "$FRPC_LOGS"
}
EOF
)
    fi
    
    # Retry with exponential backoff (5 attempts: 20s, 40s, 80s, 160s = ~5 minutes total)
    MAX_WEBHOOK_RETRIES=5
    WEBHOOK_DELAY=20
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
            if [ "$i" -lt "$MAX_WEBHOOK_RETRIES" ]; then
                log "Webhook failed (HTTP $HTTP_CODE), retrying in ${WEBHOOK_DELAY}s..."
                sleep $WEBHOOK_DELAY
                WEBHOOK_DELAY=$((WEBHOOK_DELAY * 2))  # Exponential backoff
            fi
        fi
    done
    
    if [ "$WEBHOOK_SUCCESS" = false ]; then
        log "WARNING: Failed to send webhook after $MAX_WEBHOOK_RETRIES attempts"
    fi
fi

log "Done!"

