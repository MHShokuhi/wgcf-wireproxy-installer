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
# Global variables
# --------------------------
STEP=""
TMP_DIR=""
DEFAULT_PORT="40000"

CONFIG_DIR="/etc/wireproxy"
WGCF_PROFILE="${CONFIG_DIR}/wgcf-profile.conf"
WIREPROXY_CONFIG="${CONFIG_DIR}/wireproxy.conf"

WIREPROXY_BIN="/usr/local/bin/wireproxy"
WGCF_BIN="/usr/local/bin/wgcf"

SERVICE_FILE="/etc/systemd/system/wireproxy.service"
WATCHER_SERVICE="/etc/systemd/system/wireproxy-watcher.service"
WATCHER_TIMER="/etc/systemd/system/wireproxy-watcher.timer"

HEALTH_CHECK_SCRIPT="${CONFIG_DIR}/wireproxy-watcher.sh"

# --------------------------
# Error handling
# --------------------------
cleanup_error() {
    local exit_code=$?

    trap - ERR

    if [[ -n "${STEP}" ]]; then
        echo
        echo -e "${RED}[ERROR] Failed during: ${STEP}${RESET}"
        echo "Fix the structural issue and re-run the script."
    fi

    exit "$exit_code"
}

cleanup_tmp() {
    if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
        rm -rf "$TMP_DIR"
    fi
}

trap cleanup_error ERR
trap cleanup_tmp EXIT

# Restrict permissions on newly generated keys and configs.
umask 077

# --------------------------
# UI helpers
# --------------------------
clear_screen() {
    clear 2>/dev/null || true
}

line() {
    local cols
    cols=$(tput cols 2>/dev/null || printf '80')
    printf "${BLUE}%${cols}s${RESET}\n" "" | tr ' ' '='
}

welcome_banner() {
    clear_screen
    line
    echo -e "${CYAN}${BOLD}"
    echo " ██╗    ██╗ █████╗ ██████╗ ██████╗ "
    echo " ██║    ██║██╔══██╗██╔══██╗██╔══██╗"
    echo " ██║ █╗ ██║███████║██████╔╝██████╔╝"
    echo " ██║███╗██║██╔══██║██╔══██╗██╔═══╝ "
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

info() {
    echo -e "${CYAN}[INFO]${RESET} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${RESET} $1"
}

warn() {
    echo -e "${YELLOW}[WARNING]${RESET} $1"
}

error() {
    echo -e "${RED}[ERROR]${RESET} $1"
}

# --------------------------
# Command runner
# --------------------------
spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'

    while ps -p "$pid" >/dev/null 2>&1; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        spinstr=$temp${spinstr%"$temp"}
        sleep "$delay"
        printf "\b\b\b\b\b\b"
    done

    printf "    \b\b\b\b"
}

run_cmd() {
    local msg="$1"
    shift

    local output_file
    output_file=$(mktemp)

    printf "${BLUE}➜${RESET} %s ... " "$msg"

    "$@" >"$output_file" 2>&1 &
    local pid=$!

    spinner "$pid"

    local exit_code=0

    if wait "$pid"; then
        echo -e "${GREEN}Done${RESET}"
        rm -f "$output_file"
        return 0
    else
        exit_code=$?
        echo -e "${RED}Failed${RESET}"

        echo
        echo -e "${YELLOW}Command output:${RESET}"
        tail -n 30 "$output_file" || true

        rm -f "$output_file"
        return "$exit_code"
    fi
}

# --------------------------
# WARP connectivity check
# --------------------------
check_warp() {
    local port="$1"
    local response

    response=$(
        curl -fsS \
            --connect-timeout 3 \
            --max-time 8 \
            --socks5-hostname "127.0.0.1:${port}" \
            https://www.cloudflare.com/cdn-cgi/trace \
            2>/dev/null
    ) || return 1

    grep -qxE 'warp=(on|plus)' <<< "$response"
}

# --------------------------
# Root & environment checks
# --------------------------
STEP="Pre-flight validation checks"

if [[ $EUID -ne 0 ]]; then
    error "Please run this script as root."
    exit 1
fi

if ! command -v apt >/dev/null 2>&1; then
    error "This script supports Debian/Ubuntu-based systems only."
    exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
    error "systemd is not available on this system."
    exit 1
fi

if ! id nobody >/dev/null 2>&1 || ! getent group nogroup >/dev/null 2>&1; then
    error "Required nobody:nogroup account/group not found."
    exit 1
fi

# --------------------------
# Architecture normalization
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
# Existing installation detection
# --------------------------
if [[ -f "$SERVICE_FILE" ||
      -f "$WATCHER_SERVICE" ||
      -f "$WATCHER_TIMER" ||
      -f "$WIREPROXY_BIN" ]]; then

    welcome_banner

    warn "An existing WireProxy setup was found."

    echo -e "1) ${GREEN}Update / Reconfigure${RESET}"
    echo -e "2) ${RED}Uninstall WireProxy & WGCF${RESET}"
    echo

    read -rp "Select an option [1-2]: " CHOICE </dev/tty
    echo

    if [[ "$CHOICE" == "2" ]]; then

        STEP="Uninstalling software stack"

        section_header "Starting uninstallation process"

        # Stop and disable all related services.
        systemctl disable --now wireproxy-watcher.timer \
            >/dev/null 2>&1 || true

        systemctl disable --now wireproxy-watcher.service \
            >/dev/null 2>&1 || true

        systemctl disable --now wireproxy.service \
            >/dev/null 2>&1 || true

        # Remove systemd files.
        run_cmd "Removing systemd service files" \
            rm -f "$SERVICE_FILE" "$WATCHER_SERVICE" "$WATCHER_TIMER"

        run_cmd "Reloading systemd daemon" systemctl daemon-reload

        # Remove binaries.
        if [[ -f "$WIREPROXY_BIN" ]]; then
            run_cmd "Removing WireProxy binary" rm -f "$WIREPROXY_BIN"
        fi

        if [[ -f "$WGCF_BIN" ]]; then
            run_cmd "Removing WGCF binary" rm -f "$WGCF_BIN"
        fi

        # Remove configuration and private keys.
        if [[ -d "$CONFIG_DIR" ]]; then
            run_cmd "Removing configuration files and keys" \
                rm -rf "$CONFIG_DIR"
        fi

        systemctl reset-failed >/dev/null 2>&1 || true

        echo
        line
        success "WireProxy, WGCF, services and configurations removed."
        line

        exit 0
    fi
fi

# --------------------------
# Welcome
# --------------------------
welcome_banner

info "This installer will set up:"
echo
printf "  ${GREEN}✔${RESET} WGCF (Cloudflare WARP CLI)\n"
printf "  ${GREEN}✔${RESET} Free Cloudflare WARP account\n"
printf "  ${GREEN}✔${RESET} WireProxy (WireGuard SOCKS5 proxy)\n"
printf "  ${GREEN}✔${RESET} IPv4-only WARP tunnel\n"
printf "  ${GREEN}✔${RESET} systemd auto-start service\n"
printf "  ${GREEN}✔${RESET} Persistent tunnel health watcher\n"
printf "  ${GREEN}✔${RESET} Automatic recovery on connection failure\n"
echo

read -rp "Press ENTER to continue..." </dev/tty

echo

# --------------------------
# Preserve existing port on update
# --------------------------
if [[ -f "$WIREPROXY_CONFIG" ]]; then
    EXISTING_PORT=$(
        sed -n \
            's/^[[:space:]]*BindAddress[[:space:]]*=[[:space:]]*127\.0\.0\.1:\([0-9][0-9]*\).*$/\1/p' \
            "$WIREPROXY_CONFIG" | sed -n '1p'
    )

    if [[ "$EXISTING_PORT" =~ ^[0-9]{1,5}$ ]] &&
       (( 10#$EXISTING_PORT >= 1024 && 10#$EXISTING_PORT <= 65535 )); then
        DEFAULT_PORT=$((10#$EXISTING_PORT))
    fi
fi

# --------------------------
# Ask SOCKS5 port
# --------------------------
while true; do

    read -rp "Enter local SOCKS5 port [default: ${DEFAULT_PORT}]: " \
        SOCKS_PORT </dev/tty

    SOCKS_PORT=${SOCKS_PORT:-$DEFAULT_PORT}

    if [[ "$SOCKS_PORT" =~ ^[0-9]{1,5}$ ]] &&
       (( 10#$SOCKS_PORT >= 1024 && 10#$SOCKS_PORT <= 65535 )); then

        SOCKS_PORT=$((10#$SOCKS_PORT))
        break
    else
        error "Invalid port. Enter a number between 1024 and 65535."
    fi

done

success "Using SOCKS5 port: ${SOCKS_PORT}"
echo

# --------------------------
# Stop old services during update
# --------------------------
STEP="Preparing existing installation"

systemctl disable --now wireproxy-watcher.timer \
    >/dev/null 2>&1 || true

systemctl stop wireproxy-watcher.service \
    >/dev/null 2>&1 || true

systemctl stop wireproxy.service \
    >/dev/null 2>&1 || true

# --------------------------
# Install dependencies
# --------------------------
STEP="Installing baseline dependencies"

section_header "Installing dependencies"

run_cmd "Updating package lists" apt update

run_cmd "Installing essential packages" \
    apt install -y curl wget unzip tar ca-certificates ncurses-bin file

# --------------------------
# Prepare temporary directory
# --------------------------
STEP="Preparing installation workspace"

TMP_DIR=$(mktemp -d)

mkdir -p "$CONFIG_DIR"
chmod 755 "$CONFIG_DIR"

# --------------------------
# Install WGCF
# --------------------------
STEP="Fetching and deploying WGCF binary"

section_header "Installing WGCF"

if ! WGCF_VERSION=$(
    curl -fsSL \
        --connect-timeout 10 \
        --max-time 30 \
        --retry 3 \
        https://api.github.com/repos/ViRb3/wgcf/releases/latest |
    sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' |
    sed -n '1p' |
    sed 's/^v//'
); then
    error "Failed to fetch WGCF release information."
    exit 1
fi

if [[ -z "$WGCF_VERSION" ]]; then
    error "Failed to determine latest WGCF version."
    exit 1
fi

info "Latest WGCF version: v${WGCF_VERSION}"

WGCF_URL="https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}/wgcf_${WGCF_VERSION}_linux_${WGCF_ARCH}"

# Download
run_cmd "Downloading WGCF" \
    wget -q -O "${TMP_DIR}/wgcf" "$WGCF_URL"

# Verify download
if [[ ! -s "${TMP_DIR}/wgcf" ]]; then
    error "WGCF download failed or produced an empty file."
    exit 1
fi

# Verify executable format
if ! file "${TMP_DIR}/wgcf" | grep -q 'ELF'; then
    error "Downloaded WGCF file is not a valid Linux executable."
    exit 1
fi

# Stage binary beside destination for atomic replacement
run_cmd "Preparing WGCF binary" \
    install -m 0755 "${TMP_DIR}/wgcf" "${WGCF_BIN}.new"

# Atomic deployment
run_cmd "Deploying WGCF binary" \
    mv -f "${WGCF_BIN}.new" "$WGCF_BIN"

success "WGCF installed."

# --------------------------
# Register / reuse WARP account
# --------------------------
STEP="Registering WARP account"

section_header "Setting up Cloudflare WARP account"

cd "$CONFIG_DIR"

NEW_REGISTRATION=false

if [[ -f wgcf-account.toml ]]; then

    warn "Existing WARP account detected."

    read -rp "Reuse existing account? [Y/n]: " REUSE </dev/tty

    if [[ "$REUSE" =~ ^[Nn]$ ]]; then

        info "Removing old WARP account."

        rm -f wgcf-account.toml wgcf-profile.conf

        printf '\n'
        "$WGCF_BIN" register --accept-tos </dev/tty
        printf '\n'

        success "New WARP account registered."

        NEW_REGISTRATION=true

    else

        info "Reusing existing WARP account."

    fi

else

    printf '\n'
    "$WGCF_BIN" register --accept-tos </dev/tty
    printf '\n'

    success "WARP account registered."

    NEW_REGISTRATION=true

fi

if [[ "$NEW_REGISTRATION" == true ]]; then
    info "Waiting for Cloudflare network propagation..."
    sleep 3
fi

# Protect account credentials.
if [[ -f wgcf-account.toml ]]; then
    chmod 600 wgcf-account.toml
fi

# --------------------------
# Generate WireGuard profile
# --------------------------
STEP="Generating WGCF profile"

section_header "Generating WireGuard profile"

rm -f "$WGCF_PROFILE"

"$WGCF_BIN" generate

if [[ ! -s "$WGCF_PROFILE" ]]; then
    error "Failed to generate WGCF profile."
    exit 1
fi

chmod 600 "$WGCF_PROFILE"

success "WireGuard profile generated."

# --------------------------
# Install WireProxy
# --------------------------
STEP="Fetching and deploying WireProxy binary"

section_header "Installing WireProxy"

if ! WIREPROXY_VERSION=$(
    curl -fsSL \
        --connect-timeout 10 \
        --max-time 30 \
        --retry 3 \
        https://api.github.com/repos/windtf/wireproxy/releases/latest |
    sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' |
    sed -n '1p'
); then
    error "Failed to fetch WireProxy release information."
    exit 1
fi

if [[ -z "$WIREPROXY_VERSION" ]]; then
    error "Failed to determine latest WireProxy version."
    exit 1
fi

info "Latest WireProxy version: ${WIREPROXY_VERSION}"

WIREPROXY_URL="https://github.com/windtf/wireproxy/releases/download/${WIREPROXY_VERSION}/wireproxy_${WIREPROXY_ARCH}.tar.gz"

run_cmd "Downloading WireProxy" \
    wget -q -O "${TMP_DIR}/wireproxy.tar.gz" "$WIREPROXY_URL"

run_cmd "Extracting WireProxy" \
    tar -xzf "${TMP_DIR}/wireproxy.tar.gz" -C "$TMP_DIR"

WIREPROXY_FOUND=$(
    find "$TMP_DIR" -type f -name wireproxy -print -quit
)

if [[ -z "$WIREPROXY_FOUND" ]]; then
    error "WireProxy binary not found in downloaded archive."
    exit 1
fi

run_cmd "Installing WireProxy binary" \
    install -m 0755 "$WIREPROXY_FOUND" "${TMP_DIR}/wireproxy.new"

# Atomic replacement: the previous binary remains intact if installation fails.
run_cmd "Deploying WireProxy binary" \
    mv -f "${TMP_DIR}/wireproxy.new" "$WIREPROXY_BIN"

success "WireProxy installed."

# --------------------------
# Extract WARP connection data
# --------------------------
STEP="Extracting WireGuard profile parameters"

cd "$CONFIG_DIR"

PRIVATE_KEY=$(
    sed -n 's/^[[:space:]]*PrivateKey[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' \
        "$WGCF_PROFILE" | sed -n '1p'
)

ADDRESS=$(
    sed -n 's/^[[:space:]]*Address[[:space:]]*=[[:space:]]*\([^ ,]*\).*/\1/p' \
        "$WGCF_PROFILE" | sed -n '1p'
)

PUBLIC_KEY=$(
    sed -n 's/^[[:space:]]*PublicKey[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' \
        "$WGCF_PROFILE" | sed -n '1p'
)

ENDPOINT=$(
    sed -n 's/^[[:space:]]*Endpoint[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' \
        "$WGCF_PROFILE" | sed -n '1p'
)

if [[ -z "$PRIVATE_KEY" ||
      -z "$ADDRESS" ||
      -z "$PUBLIC_KEY" ||
      -z "$ENDPOINT" ]]; then

    error "Failed to parse required fields from WGCF profile."
    exit 1
fi

if [[ "$ADDRESS" != */* ]]; then
    error "Invalid WireGuard address in WGCF profile."
    exit 1
fi

# --------------------------
# Create WireProxy config
# --------------------------
STEP="Creating WireProxy backend configuration"

section_header "Creating IPv4-only WireProxy config"

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
chown nobody:nogroup "$WIREPROXY_CONFIG"

success "WireProxy configuration created."

# --------------------------
# Create persistent health watcher
# --------------------------
STEP="Generating persistent health watcher"

section_header "Creating tunnel health watcher"

cat > "$HEALTH_CHECK_SCRIPT" <<EOF
#!/usr/bin/env bash

set -u

SOCKS_PORT="${SOCKS_PORT}"
CHECK_URL="https://www.cloudflare.com/cdn-cgi/trace"

check_warp() {
    local response

    response=\$(curl -fsS \
        --connect-timeout 3 \
        --max-time 8 \
        --socks5-hostname "127.0.0.1:\${SOCKS_PORT}" \
        "\${CHECK_URL}" 2>/dev/null) || return 1

    grep -qxE 'warp=(on|plus)' <<< "\$response"
}

log_failure() {
    logger -p daemon.warning -t wireproxy-watcher "\$1"
}

while true; do

    if ! check_warp; then

        log_failure "WARP health check failed. Restarting WireProxy."

        if ! systemctl restart wireproxy; then

            log_failure "Failed to restart WireProxy."

        else

            RECOVERED=false

            for attempt in {1..3}; do

                sleep 3

                if check_warp; then
                    RECOVERED=true
                    break
                fi

            done

            if [[ "\$RECOVERED" == false ]]; then

                logger -p daemon.err -t wireproxy-watcher \
                    "WARP connection remains unhealthy after restart."

            fi

        fi

    fi

    sleep 60

done
EOF

chmod 755 "$HEALTH_CHECK_SCRIPT"
chown root:root "$HEALTH_CHECK_SCRIPT"

success "Persistent health watcher created."

# --------------------------
# Validate WireProxy config
# --------------------------
STEP="Validating WireProxy configuration"

section_header "Validating configuration"

if ! "$WIREPROXY_BIN" -c "$WIREPROXY_CONFIG" -n \
    >/dev/null 2>&1; then

    error "Generated WireProxy configuration is invalid."
    exit 1
fi

success "WireProxy configuration validated."

# --------------------------
# Create WireProxy systemd service
# --------------------------
STEP="Deploying WireProxy systemd service"

section_header "Creating WireProxy service"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=WireProxy WARP connection
Wants=network-online.target
After=network-online.target

StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=nobody
Group=nogroup
NoNewPrivileges=true

ExecStart=${WIREPROXY_BIN} -c ${WIREPROXY_CONFIG}

Restart=always
RestartSec=5

LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

# --------------------------
# Create persistent watcher systemd service
# --------------------------
STEP="Deploying health watcher systemd service"

cat > "$WATCHER_SERVICE" <<EOF
[Unit]
Description=WireProxy WARP Health Watcher
Wants=network-online.target wireproxy.service
After=network-online.target wireproxy.service

[Service]
Type=simple
ExecStart=${HEALTH_CHECK_SCRIPT}

Restart=on-failure
RestartSec=5
TimeoutStopSec=10

StandardOutput=null
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Remove obsolete timer-based watcher.
rm -f "$WATCHER_TIMER"

# --------------------------
# Reload and enable services
# --------------------------
STEP="Enabling systemd services"

section_header "Enabling background services"

run_cmd "Reloading systemd daemon" systemctl daemon-reload

run_cmd "Enabling WireProxy service" systemctl enable wireproxy.service

run_cmd "Enabling persistent health watcher" \
    systemctl enable wireproxy-watcher.service

# --------------------------
# Final startup and validation
# --------------------------
STEP="Verifying tunnel startup and connectivity"

section_header "Starting and verifying WARP tunnel"

printf "${BLUE}➜${RESET} Starting WireProxy ... "

systemctl start wireproxy.service

echo -e "${GREEN}Started${RESET}"

info "Waiting for WARP tunnel connectivity..."

VALIDATED=false

for attempt in {1..12}; do

    if check_warp "$SOCKS_PORT"; then
        VALIDATED=true
        break
    fi

    if [[ "$attempt" -lt 12 ]]; then
        sleep 3
    fi

done

if [[ "$VALIDATED" == false ]]; then

    echo
    error "WARP connection could not be verified."

    info "WireProxy service status:"
    systemctl status wireproxy.service --no-pager || true

    info "Recent WireProxy logs:"
    journalctl -u wireproxy.service -n 25 --no-pager || true

    exit 1
fi

success "WARP tunnel connectivity verified."

# --------------------------
# Start persistent watcher
# --------------------------
STEP="Starting persistent health watcher"

run_cmd "Starting health watcher" \
    systemctl start wireproxy-watcher.service

if ! systemctl is-active --quiet wireproxy-watcher.service; then
    error "Health watcher failed to start."
    exit 1
fi

success "Persistent health watcher is active."

# --------------------------
# Final output
# --------------------------
STEP="Finalizing installation"

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

echo -e "${WHITE}${BOLD}Service Status${RESET}"
echo

printf "  ${CYAN}WireProxy:${RESET} "
systemctl is-active wireproxy.service

printf "  ${CYAN}Watcher:${RESET}   "
systemctl is-active wireproxy-watcher.service

echo
line

echo -e "${WHITE}${BOLD}Useful Management Commands${RESET}"
echo

printf "  ${YELLOW}systemctl status wireproxy${RESET}\n"
printf "  ${YELLOW}systemctl restart wireproxy${RESET}\n"
printf "  ${YELLOW}systemctl status wireproxy-watcher${RESET}\n"
printf "  ${YELLOW}systemctl restart wireproxy-watcher${RESET}\n"
printf "  ${YELLOW}journalctl -u wireproxy -f${RESET}\n"
printf "  ${YELLOW}journalctl -t wireproxy-watcher -f${RESET}\n"
printf "  ${YELLOW}journalctl -u wireproxy-watcher -p warning${RESET}\n"

echo
line

echo -e "${GREEN}Everything is installed and connectivity has been verified.${RESET}"
echo

STEP=""
