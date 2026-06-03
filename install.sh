#!/usr/bin/env bash

set -euo pipefail

# =====================================================
# WGCF + WireProxy Installer
# =====================================================

# --------------------------
# Colors
# --------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
BOLD='\033[1m'
RESET='\033[0m'

# --------------------------
# Step counter
# --------------------------
STEP=""

cleanup() {
    local exit_code=$?
    if [[ ${exit_code} -ne 0 && -n "${STEP}" ]]; then
        echo ""
        echo -e "${RED}[ERROR] Failed during: ${STEP}${RESET}"
        echo "Fix the structural issue and re-run the script."
    fi
    exit ${exit_code}
}
trap cleanup ERR

clear_screen() {
    clear
}

line() {
    local cols
    cols=$(tput cols 2>/dev/null || echo 80)
    printf "${BLUE}%${cols}s${RESET}\n" | tr ' ' '='
}

welcome_banner() {
    clear_screen
    line
    echo -e "${CYAN}${BOLD}"
    echo " ██╗    ██╗ █████╗ ██████╗ ██████╗ "
    echo " ██║    ██║██╔══██╗██╔══██╗██╔══██╗"
    echo " ██║ █╗ ██║███████║██████╔╝██████╔╝"
    echo " ██║███╗██║██╔══██║██╔══██║██╔═══╝ "
    echo " ╚███╔███╔╝██║  ██║██║  ██║██║     "
    echo "  ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝     "
    echo -e "${RESET}"
    echo -e "${WHITE}${BOLD} WGCF + WireProxy Installer${RESET}"
    line
    echo
}

section_header() {
    echo
    echo -e "${BLUE}══> ${WHITE}${BOLD}$1${RESET}"
    echo
}

info() { echo -e "${CYAN}[INFO]${RESET} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${RESET} $1"; }
warn() { echo -e "${YELLOW}[WARNING]${RESET} $1"; }
error() { echo -e "${RED}[ERROR]${RESET} $1"; }

spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\\\'
    while ps -p "$pid" > /dev/null 2>&1; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

run_cmd() {
    local msg="$1"
    shift

    printf "${BLUE}➜${RESET} %s ... " "$msg"

    "$@" >/dev/null 2>&1 &
    local pid=$!

    spinner $pid

    set +e
    wait $pid
    local exit_code=$?
    set -e

    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}Done${RESET}"
    else
        echo -e "${RED}Failed${RESET}"
        exit 1
    fi
}

# --------------------------
# Root & Env Check
# --------------------------
STEP="Pre-flight validation checks"
if [[ $EUID -ne 0 ]]; then
    error "Please run this script as root"
    exit 1
fi

if ! command -v apt >/dev/null 2>&1; then
    error "This script currently supports Debian/Ubuntu based systems only"
    exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
    error "systemd is not available on this system"
    exit 1
fi

# --------------------------
# Variables
# --------------------------
CONFIG_DIR="/etc/wireproxy"
WGCF_PROFILE="${CONFIG_DIR}/wgcf-profile.conf"
WIREPROXY_CONFIG="${CONFIG_DIR}/wireproxy.conf"
WIREPROXY_BIN="/usr/local/bin/wireproxy"
WGCF_BIN="/usr/local/bin/wgcf"
SERVICE_FILE="/etc/systemd/system/wireproxy.service"
WATCHER_SERVICE="/etc/systemd/system/wireproxy-watcher.service"
WATCHER_TIMER="/etc/systemd/system/wireproxy-watcher.timer"
HEALTH_CHECK_SCRIPT="${CONFIG_DIR}/wireproxy-watcher.sh"
DEFAULT_PORT="40000"

# --------------------------
# Architecture Normalization
# --------------------------
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)
        WGCF_ARCH="amd64"
        WIREPROXY_ARCH="linux_amd64"
        ;;
    aarch64|arm64)
        WGCF_ARCH="arm64"
        WIREPROXY_ARCH="linux_arm64"
        ;;
    armv7l|armv8l)
        WGCF_ARCH="armv7"
        WIREPROXY_ARCH="linux_arm"
        ;;
    *)
        error "Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

# --------------------------
# Menu / Choices
# --------------------------
echo

if [[ -f "$SERVICE_FILE" ]] || [[ -f "$WIREPROXY_BIN" ]]; then
    welcome_banner
    warn "An existing wireproxy setup was found on this system."
    echo -e "1) ${GREEN}Update / Reconfigure${RESET}"
    echo -e "2) ${RED}Uninstall wireproxy & wgcf${RESET}"
    echo
    read -rp "Select an option [1-2]: " CHOICE </dev/tty
    echo

    if [[ "$CHOICE" == "2" ]]; then
        STEP="Uninstalling software stack"
        section_header "Starting uninstallation process..."
        echo

        if systemctl list-unit-files | grep -q "^wireproxy-watcher.timer"; then
            run_cmd "Stopping watcher timer" systemctl stop wireproxy-watcher.timer || true
            run_cmd "Disabling watcher timer" systemctl disable wireproxy-watcher.timer || true
        fi

        if systemctl list-unit-files | grep -q "^wireproxy.service"; then
            run_cmd "Stopping wireproxy service" systemctl stop wireproxy || true
            run_cmd "Disabling wireproxy service" systemctl disable wireproxy || true
        fi

        if [[ -f "$SERVICE_FILE" ]]; then
            run_cmd "Removing systemd service files" rm -f "$SERVICE_FILE" "$WATCHER_SERVICE" "$WATCHER_TIMER"
            run_cmd "Reloading systemd daemon" systemctl daemon-reload
        fi

        if [[ -f "$WIREPROXY_BIN" ]]; then
            run_cmd "Removing wireproxy binary" rm -f "$WIREPROXY_BIN"
        fi
        if [[ -f "$WGCF_BIN" ]]; then
            run_cmd "Removing wgcf binary" rm -f "$WGCF_BIN"
        fi

        if [[ -d "$CONFIG_DIR" ]]; then
            run_cmd "Cleaning configuration files & keys" rm -rf "$CONFIG_DIR"
        fi

        echo
        line
        success "wgcf & wireproxy & their leftover configs have been entirely removed!"
        line
        exit 0
    fi
fi

# --------------------------
# Start Installation
# --------------------------
welcome_banner
info "This installer will setup:"
echo
printf "  ${GREEN}✔${RESET} wgcf (unofficial, cross-platform CLI for Cloudflare Warp)\n"
printf "  ${GREEN}✔${RESET} Free Cloudflare WARP account via wgcf\n"
printf "  ${GREEN}✔${RESET} wireproxy (A wireguard client that exposes itself as a socks5/http proxy or tunnels)\n"
printf "  ${GREEN}✔${RESET} SOCKS5 endpoint proxy routing layer via wireproxy\n"
printf "  ${GREEN}✔${RESET} systemd auto-start service & tunnel health watcher\n"
echo

read -rp "Press ENTER to continue..." </dev/tty

echo

# --------------------------
# Ask Port
# --------------------------
while true; do
    read -rp "Enter local SOCKS5 port [default: ${DEFAULT_PORT}]: " SOCKS_PORT </dev/tty
    SOCKS_PORT=${SOCKS_PORT:-$DEFAULT_PORT}

    if [[ "$SOCKS_PORT" =~ ^[0-9]+$ ]] && [ "$SOCKS_PORT" -ge 1024 ] && [ "$SOCKS_PORT" -le 65535 ]; then
        break
    else
        error "Invalid port number. Must be a digit between 1024 and 65535."
    fi
done

success "Using SOCKS5 port: ${SOCKS_PORT}"
echo

# --------------------------
# Install Dependencies
# --------------------------
STEP="Installing baseline dependencies (curl wget unzip tar ca-certificates ncurses-bin)"
info "Installing dependencies"
run_cmd "Updating package lists" apt update
run_cmd "Installing essential packages" apt install -y curl wget unzip tar ca-certificates ncurses-bin

# --------------------------
# Install wgcf
# --------------------------
STEP="Fetching and deploying wgcf binaries"
section_header "Installing wgcf"

WGCF_VERSION=$(curl -fsSL https://api.github.com/repos/ViRb3/wgcf/releases/latest | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1 | tr -d 'v')

if [[ -z "$WGCF_VERSION" ]]; then
    error "Failed to fetch latest wgcf version"
    exit 1
fi

info "Latest wgcf version: v${WGCF_VERSION}"

WGCF_URL="https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}/wgcf_${WGCF_VERSION}_linux_${WGCF_ARCH}"

run_cmd "Downloading wgcf" wget -O "$WGCF_BIN" "$WGCF_URL"
run_cmd "Making wgcf executable" chmod +x "$WGCF_BIN"

success "wgcf installed"

# --------------------------
# Prepare Directory
# --------------------------
mkdir -p "$CONFIG_DIR"
cd "$CONFIG_DIR"

# --------------------------
# Register WARP Account
# --------------------------
STEP="Registering WARP account via wgcf"
section_header "Setting up Cloudflare WARP account"

NEW_REGISTRATION=false

if [[ -f wgcf-account.toml ]]; then
    warn "Existing WARP account detected"
    read -rp "Reuse existing account? [Y/n]: " REUSE </dev/tty

    if [[ "$REUSE" =~ ^[Nn]$ ]]; then
        info "Removing old WARP account"
        rm -f wgcf-account.toml wgcf-profile.conf

        printf '\n'
        wgcf register --accept-tos </dev/tty
        printf '\n'
        success "New WARP account registered"
        NEW_REGISTRATION=true
    else
        info "Reusing existing WARP account"
    fi
else
    printf '\n'
    wgcf register --accept-tos </dev/tty
    printf '\n'
    success "WARP account registered"
    NEW_REGISTRATION=true
fi

if [[ "$NEW_REGISTRATION" = true ]]; then
    info "Waiting for Cloudflare network propagation..."
    sleep 3
fi

# --------------------------
# Generate Profile
# --------------------------
STEP="Generating wgcf profile"
section_header "Generating WireGuard profile"

rm -f wgcf-profile.conf
wgcf generate

if [[ ! -f "wgcf-profile.conf" ]]; then
    error "Failed to generate wgcf profile"
    exit 1
fi

success "WireGuard profile generated"

# --------------------------
# Install wireproxy
# --------------------------
STEP="Checking, fetching and deploying wireproxy binaries & service"
section_header "Installing wireproxy"

if systemctl list-unit-files | grep -q "^wireproxy.service"; then
    run_cmd "Stopping active wireproxy service for update" systemctl stop wireproxy || true
    sleep 1
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

cd "$TMP_DIR"

WIREPROXY_VERSION=$(curl -fsSL https://api.github.com/repos/windtf/wireproxy/releases/latest | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)

if [[ -z "$WIREPROXY_VERSION" ]]; then
    error "Failed to fetch latest wireproxy version"
    exit 1
fi

WIREPROXY_URL="https://github.com/windtf/wireproxy/releases/download/${WIREPROXY_VERSION}/wireproxy_${WIREPROXY_ARCH}.tar.gz"

run_cmd "Downloading wireproxy" wget -O wireproxy.tar.gz "$WIREPROXY_URL"
run_cmd "Extracting wireproxy" tar -xzf wireproxy.tar.gz

WIREPROXY_FOUND=$(find . -type f -name wireproxy | head -n 1)

if [[ -z "$WIREPROXY_FOUND" ]]; then
    error "wireproxy binary not found"
    exit 1
fi

run_cmd "Deploying wireproxy binary" install -p -m 0755 "$WIREPROXY_FOUND" "$WIREPROXY_BIN"

trap - EXIT
rm -rf "$TMP_DIR"

success "wireproxy installed"

# --------------------------
# Extract WARP Connection Data
# --------------------------
cd "$CONFIG_DIR"
PRIVATE_KEY=$(sed -n 's/^PrivateKey *= *\([^ ]*\)/\1/p' "$WGCF_PROFILE")
ADDRESS=$(sed -n 's/^Address *= *\([^ ,]*\).*/\1/p' "$WGCF_PROFILE")
PUBLIC_KEY=$(sed -n 's/^PublicKey *= *\([^ ]*\)/\1/p' "$WGCF_PROFILE")
ENDPOINT=$(sed -n 's/^Endpoint *= *\([^ ]*\)/\1/p' "$WGCF_PROFILE")

if [[ -z "$PRIVATE_KEY" || -z "$ADDRESS" || -z "$PUBLIC_KEY" || -z "$ENDPOINT" ]]; then
    error "Failed to parse required fields from wgcf profile"
    exit 1
fi

# --------------------------
# Create wireproxy Config
# --------------------------
STEP="Creating wireproxy backend config"
section_header "Creating IPv4-only wireproxy config"

cat > "$WIREPROXY_CONFIG" <<EOF
[Interface]
PrivateKey = ${PRIVATE_KEY}
Address = ${ADDRESS}
DNS = 1.1.1.1
MTU = 1280

[Peer]
PublicKey = ${PUBLIC_KEY}
AllowedIPs = 0.0.0.0/0
Endpoint = ${ENDPOINT}
PersistentKeepalive = 25

[Socks5]
BindAddress = 127.0.0.1:${SOCKS_PORT}
EOF

chmod 600 "$WIREPROXY_CONFIG"
success "wireproxy config created"

# --------------------------
# Create Internal Watcher Script & Self-Healing
# --------------------------
STEP="Generating health watcher & auto-healing loops"
cat > "$HEALTH_CHECK_SCRIPT" <<EOF
#!/usr/bin/env bash
SOCKS_PORT="${SOCKS_PORT}"
if ! curl -s --max-time 5 --socks5 127.0.0.1:"\$SOCKS_PORT" https://www.cloudflare.com/cdn-cgi/trace | grep -E -q "warp=(on|plus)" >/dev/null 2>&1; then
    systemctl restart wireproxy >/dev/null 2>&1
fi
EOF

chmod +x "$HEALTH_CHECK_SCRIPT"

# --------------------------
# Create systemd Service
# --------------------------
STEP="Deploying systemd background services"
section_header "Creating systemd service"

if ! "${WIREPROXY_BIN}" -c "${WIREPROXY_CONFIG}" -n >/dev/null 2>&1; then
    error "Generated wireproxy configuration is invalid!"
    exit 1
fi

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=wireproxy WARP connection
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${WIREPROXY_BIN} -c ${WIREPROXY_CONFIG}
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

cat > "$WATCHER_SERVICE" <<EOF
[Unit]
Description=wireproxy Health Watcher Worker
After=wireproxy.service

[Service]
Type=oneshot
ExecStart=${HEALTH_CHECK_SCRIPT}
EOF

cat > "$WATCHER_TIMER" <<EOF
[Unit]
Description=Run wireproxy Health Watcher every minute

[Timer]
OnActiveSec=30
OnUnitActiveSec=60

[Install]
WantedBy=timers.target
EOF

run_cmd "Reloading systemd" systemctl daemon-reload
run_cmd "Enabling wireproxy service" systemctl enable wireproxy
run_cmd "Enabling watcher timer" systemctl enable wireproxy-watcher.timer

# --------------------------
# Final Status Validation
# --------------------------
STEP="Verifying tunnel startup state and condition"
section_header "Starting and Tuning Tunnel Stabilization Link"

printf "${BLUE}➜${RESET} Synchronizing proxy socket interfaces ... "

systemctl stop wireproxy >/dev/null 2>&1 || true
systemctl start wireproxy

# Let the interface settle and allow first-time routing keys to populate down
sleep 5

# Systematic validation verification sequence
VALIDATED=false
for i in {1..6}; do
    if curl -s --max-time 4 --socks5 127.0.0.1:"${SOCKS_PORT}" https://www.cloudflare.com/cdn-cgi/trace | grep -E -q "warp=(on|plus)" >/dev/null 2>&1; then
        VALIDATED=true
        break
    fi
    sleep 3
done

if [ "$VALIDATED" = true ]; then
    systemctl start wireproxy-watcher.timer >/dev/null 2>&1 || true
    echo -e "${GREEN}Connected & Fully Stabilized!${RESET}"
else
    echo -e "${RED}Verification Stalled${RESET}"
    error "The connection handshake failed to verify connection."
    info "Review latest logs via: journalctl -u wireproxy -n 25"
    exit 1
fi

# --------------------------
# Final Output
# --------------------------
clear_screen
line
echo -e "${GREEN}${BOLD}WARP Setup Completed Successfully!${RESET}"
echo
line

echo -e "${WHITE}${BOLD}SOCKS5 Details${RESET}"
echo
printf "  ${CYAN}Address:${RESET} 127.0.0.1\n"
printf "  ${CYAN}Port:${RESET}    %s\n" "$SOCKS_PORT"
printf "  ${CYAN}Protocol:${RESET} SOCKS5\n"
echo
line

echo -e "${WHITE}${BOLD}Useful Management Commands${RESET}"
echo
printf "  ${YELLOW}systemctl status wireproxy${RESET}\n"
printf "  ${YELLOW}systemctl restart wireproxy${RESET}\n"
printf "  ${YELLOW}journalctl -u wireproxy -f${RESET}\n"
echo
line
echo -e "${GREEN}Everything is fully operational and verified.${RESET}"
echo
STEP=""