#!/bin/bash
#
# Centrunk DVMHost Installation Script
# Automates installation on Raspberry Pi OS Bookworm/Trixie (64-bit)
#
# Usage: sudo ./install.sh [options]
#   Options:
#     --skip-netbird         Skip Netbird installation
#     --skip-services        Skip systemd service installation
#     --skip-firmware-build  Skip firmware compilation
#     --skip-platform-check  Skip platform verification (for testing)
#     --skip-device-setup    Skip device authorization config provisioning
#     --ctrs-url <url>       CTRS server URL (default: https://my.centrunk.net)
#     -y, --yes              Non-interactive mode (assume yes to prompts)
#     --help                 Show this help message
#
# One-liner installation:
#   curl -fsSL https://raw.githubusercontent.com/Centrunk/hotspot-installer/main/install.sh | sudo bash
#

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Binary download URL
DVMHOST_BINS_REPO="https://github.com/Centrunk/dvmbins/raw/master"

# Installer repo (for downloading service files, etc. when running via pipe)
INSTALLER_REPO_RAW="https://raw.githubusercontent.com/Centrunk/hotspot-installer/main"

# CTRS server URL (for device authorization flow)
CTRS_URL="${CTRS_URL:-https://my.centrunk.net}"

# Default options
SKIP_NETBIRD=false
SKIP_SERVICES=false
SKIP_FIRMWARE_BUILD=false
SKIP_PLATFORM_CHECK=false
SKIP_DEVICE_SETUP=false
NON_INTERACTIVE=false
DEVICE_SETUP_COMPLETED=false
FIRMWARE_CHANGED=true
NETBIRD_SETUP_KEY=""
NETBIRD_AUTO_CONNECTED=false

# Determine the real (non-root) user who invoked this script.
# When run via `sudo`, SUDO_USER is the original user; fall back to $USER.
REAL_USER="${SUDO_USER:-$USER}"

# Detect if running from a pipe (non-interactive)
if [[ ! -t 0 ]]; then
    NON_INTERACTIVE=true
fi

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-netbird)
            SKIP_NETBIRD=true
            shift
            ;;
        --skip-services)
            SKIP_SERVICES=true
            shift
            ;;
        --skip-firmware-build)
            SKIP_FIRMWARE_BUILD=true
            shift
            ;;
        --skip-platform-check)
            SKIP_PLATFORM_CHECK=true
            shift
            ;;
        --skip-device-setup)
            SKIP_DEVICE_SETUP=true
            shift
            ;;
        --ctrs-url)
            CTRS_URL="$2"
            shift 2
            ;;
        -y|--yes)
            NON_INTERACTIVE=true
            shift
            ;;
        --help)
            echo "Centrunk DVMHost Installation Script"
            echo ""
            echo "Usage: sudo ./install.sh [options]"
            echo ""
            echo "Options:"
            echo "  --skip-netbird         Skip Netbird installation"
            echo "  --skip-services        Skip systemd service installation"
            echo "  --skip-firmware-build  Skip firmware compilation"
            echo "  --skip-platform-check  Skip platform verification (for testing)"
            echo "  --skip-device-setup    Skip device authorization config provisioning"
            echo "  --ctrs-url <url>       CTRS server URL (default: https://my.centrunk.net)"
            echo "  -y, --yes              Non-interactive mode (assume yes to prompts)"
            echo "  --help                 Show this help message"
            echo ""
            echo "One-liner installation:"
            echo "  curl -fsSL https://raw.githubusercontent.com/Centrunk/hotspot-installer/main/install.sh | sudo bash"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Function to print status messages
print_status() {
    echo -e "${GREEN}[*]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}[X]${NC} $1"
}

# Detect system architecture
detect_arch() {
    local arch
    arch=$(uname -m)
    
    case "$arch" in
        aarch64|arm64)
            echo "arm64"
            ;;
        armv7l|armhf)
            echo "armhf"
            ;;
        x86_64|amd64)
            echo "amd64"
            ;;
        *)
            print_error "Unsupported architecture: $arch"
            exit 1
            ;;
    esac
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Verify platform and architecture requirements
check_platform() {
    if [[ "$SKIP_PLATFORM_CHECK" == "true" ]]; then
        print_warning "Skipping platform verification (--skip-platform-check flag)"
        return
    fi
    
    print_status "Verifying platform and architecture..."
    
    local errors=0
    
    # Check architecture - must be 64-bit ARM
    local arch
    arch=$(uname -m)
    if [[ "$arch" != "aarch64" ]]; then
        print_error "This installer requires 64-bit ARM architecture (aarch64)"
        print_error "Detected architecture: $arch"
        errors=$((errors + 1))
    else
        print_status "Architecture: $arch ✓"
    fi
    
    # Check OS release file exists
    if [[ ! -f /etc/os-release ]]; then
        print_error "Cannot detect OS - /etc/os-release not found"
        exit 1
    fi
    
    # shellcheck source=/dev/null
    . /etc/os-release
    
    # Check for Raspberry Pi OS specifically
    # Raspberry Pi OS sets ID=debian but has "Raspberry Pi" in PRETTY_NAME
    # It also has /etc/rpi-issue file
    local is_rpi_os=false
    if [[ -f /etc/rpi-issue ]]; then
        is_rpi_os=true
    elif [[ "$PRETTY_NAME" == *"Raspberry Pi"* ]]; then
        is_rpi_os=true
    elif [[ "$ID" == "raspbian" ]]; then
        is_rpi_os=true
    fi
    
    if [[ "$is_rpi_os" != "true" ]]; then
        print_error "This installer requires Raspberry Pi OS"
        print_error "Detected OS: $PRETTY_NAME"
        errors=$((errors + 1))
    else
        print_status "Operating System: Raspberry Pi OS ✓"
    fi
    
    # Check for Bookworm (Debian 12) or Trixie (Debian 13)
    if [[ "$VERSION_CODENAME" != "bookworm" && "$VERSION_CODENAME" != "trixie" ]]; then
        print_error "This installer requires Raspberry Pi OS Bookworm or Trixie"
        print_error "Detected version: $VERSION_CODENAME"
        errors=$((errors + 1))
    else
        print_status "Version: $VERSION_CODENAME ✓"
    fi
    
    # Check for 64-bit OS (not just 64-bit CPU)
    local os_arch
    os_arch=$(getconf LONG_BIT)
    if [[ "$os_arch" != "64" ]]; then
        print_error "This installer requires 64-bit Raspberry Pi OS"
        print_error "Detected: ${os_arch}-bit OS"
        errors=$((errors + 1))
    else
        print_status "OS Architecture: 64-bit ✓"
    fi
    
    # Exit if any checks failed
    if [[ $errors -gt 0 ]]; then
        echo ""
        print_error "Platform verification failed with $errors error(s)"
        print_error "This installer requires: Raspberry Pi OS Bookworm/Trixie 64-bit"
        echo ""
        if [[ "$NON_INTERACTIVE" == "true" ]]; then
            print_error "Non-interactive mode: aborting due to platform mismatch"
            print_error "Use --skip-platform-check to bypass this check"
            exit 1
        fi
        read -p "Continue anyway? (y/N) " -n 1 -r < /dev/tty
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
        print_warning "Continuing despite platform mismatch - this may cause issues!"
    else
        print_status "Platform verification passed!"
    fi
}

# Install prerequisites
install_prerequisites() {
    print_status "Updating package lists..."
    apt-get update

    print_status "Installing prerequisites..."
    apt-get install -y \
        git \
        curl \
        wget \
        jq \
        unzip \
        xz-utils \
        stm32flash \
        make \
        gcc-arm-none-eabi \
        binutils-arm-none-eabi \
        libnewlib-arm-none-eabi

    print_status "Prerequisites installed successfully"
}

# Install Netbird
install_netbird() {
    if [[ "$SKIP_NETBIRD" == "true" ]]; then
        print_warning "Skipping Netbird installation (--skip-netbird flag)"
        return
    fi

    # Track whether NetBird was already running before we touched it
    if systemctl is-active --quiet netbird 2>/dev/null || pgrep -x netbird >/dev/null 2>&1; then
        NETBIRD_ALREADY_RUNNING=true
    fi

    # Always ensure the binary is installed (idempotent — installer handles upgrades)
    if ! command -v netbird &>/dev/null; then
        print_status "Installing Netbird..."
        curl -fsSL https://pkgs.netbird.io/install.sh | sh
        print_status "Netbird installed successfully"
    else
        print_status "Netbird binary already installed"
    fi
}

# Create directory structure
create_directories() {
    print_status "Creating directory structure..."

    # Create log directory
    if [[ ! -d /var/log/centrunk ]]; then
        mkdir -p /var/log/centrunk
        print_status "Created /var/log/centrunk"
    else
        print_warning "/var/log/centrunk already exists"
    fi

    # Create main directory
    if [[ ! -d /opt/centrunk ]]; then
        mkdir -p /opt/centrunk
        print_status "Created /opt/centrunk"
    else
        print_warning "/opt/centrunk already exists"
    fi

    # Create configs directory
    if [[ ! -d /opt/centrunk/configs ]]; then
        mkdir -p /opt/centrunk/configs
        print_status "Created /opt/centrunk/configs"
    else
        print_warning "/opt/centrunk/configs already exists"
    fi

    # Create dvmhost directory
    if [[ ! -d /opt/centrunk/dvmhost ]]; then
        mkdir -p /opt/centrunk/dvmhost
        print_status "Created /opt/centrunk/dvmhost"
    else
        print_warning "/opt/centrunk/dvmhost already exists"
    fi
}

# Clone DVMProject firmware source
clone_firmware() {
    local dest="/opt/centrunk/dvmfirmware-hs"

    if [[ -d "$dest" ]]; then
        print_warning "$dest already exists - pulling latest changes"
        local pull_output
        if pull_output=$(git -C "$dest" pull --recurse-submodules 2>&1); then
            if echo "$pull_output" | grep -q "Already up to date"; then
                print_status "Firmware source already up to date"
                FIRMWARE_CHANGED=false
            else
                print_status "Firmware source updated"
                FIRMWARE_CHANGED=true
            fi
        else
            print_warning "git pull failed - continuing with existing checkout"
            FIRMWARE_CHANGED=true
        fi
        return
    fi

    print_status "Cloning dvmfirmware-hs..."
    if ! git clone --recurse-submodules https://github.com/DVMProject/dvmfirmware-hs.git "$dest"; then
        print_error "Failed to clone dvmfirmware-hs"
        exit 1
    fi
    FIRMWARE_CHANGED=true
    print_status "dvmfirmware-hs cloned to $dest"
}

# Build firmware for MMDVM_HS_Hat (dual)
build_firmware() {
    if [[ "$SKIP_FIRMWARE_BUILD" == "true" ]]; then
        print_warning "Skipping firmware build (--skip-firmware-build flag)"
        return
    fi

    if [[ "$FIRMWARE_CHANGED" != "true" ]]; then
        print_status "Firmware source unchanged - skipping rebuild"
        return
    fi

    local src="/opt/centrunk/dvmfirmware-hs"

    if [[ ! -d "$src" ]]; then
        print_error "Firmware source not found at $src - cannot build"
        exit 1
    fi

    print_status "Cleaning firmware build directory..."
    if ! make -C "$src" -f Makefile.STM32FX clean; then
        print_warning "Firmware clean failed - continuing with build"
    fi

    print_status "Building dvmfirmware-hs (mmdvm-hs-hat-dual)..."
    if ! make -C "$src" -f Makefile.STM32FX mmdvm-hs-hat-dual; then
        print_error "Firmware build failed"
        exit 1
    fi
    print_status "Firmware build complete"
}

# Remove console parameters from boot cmdline
remove_console_params() {
    local modified=false
    local cmdline_file="/boot/firmware/cmdline.txt"
    if [[ -f "$cmdline_file" ]] && grep -q "console=" "$cmdline_file"; then
        cp "$cmdline_file" "${cmdline_file}.backup"
        sed -i 's/console=[^ ]*//g; s/  */ /g; s/^ //; s/ $//' "$cmdline_file"
        modified=true
    fi
    if [[ "$modified" == "true" ]]; then
        print_warning "Boot cmdline modified - reboot required"
    fi
}

# Disable Bluetooth to free up ttyAMA0
disable_bluetooth() {
    local config_file="/boot/firmware/config.txt"
    if [[ ! -f "$config_file" ]]; then
        print_warning "No config.txt found - skipping Bluetooth disable"
        return
    fi
    
    # Detect Pi model
    local pi_model=""
    if [[ -f /proc/device-tree/model ]]; then
        local model_str
        model_str=$(tr -d '\0' < /proc/device-tree/model)
        if [[ "$model_str" == *"Raspberry Pi 5"* ]]; then
            pi_model="pi5"
        elif [[ "$model_str" == *"Raspberry Pi 4"* ]]; then
            pi_model="pi4"
        elif [[ "$model_str" == *"Raspberry Pi 3"* ]]; then
            pi_model="pi3"
        fi
    fi
    
    if [[ -z "$pi_model" ]]; then
        print_warning "Could not detect Pi model - skipping Bluetooth configuration"
        return
    fi
    
    cp "$config_file" "${config_file}.backup"
    
    # Ensure [all] section exists
    if ! grep -q "^\[all\]" "$config_file"; then
        echo -e "\n[all]" >> "$config_file"
    fi
    
    case "$pi_model" in
        pi3)
            if ! grep -q "^dtoverlay=pi3-disable-bt" "$config_file"; then
                sed -i '/^\[all\]/a dtoverlay=pi3-disable-bt' "$config_file"
                print_status "Added Pi 3 Bluetooth disable to $config_file"
            fi
            ;;
        pi4)
            if ! grep -q "^dtoverlay=disable-bt" "$config_file"; then
                sed -i '/^\[all\]/a dtoverlay=disable-bt' "$config_file"
                print_status "Added Pi 4 Bluetooth disable to $config_file"
            fi
            ;;
        pi5)
            if ! grep -q "^dtoverlay=uart0,ctsrts" "$config_file"; then
                sed -i '/^\[all\]/a dtoverlay=uart0,ctsrts' "$config_file"
                print_status "Added dtoverlay=uart0,ctsrts to $config_file"
            fi
            if ! grep -q "^enable_uart=1" "$config_file"; then
                sed -i '/^\[all\]/a enable_uart=1' "$config_file"
                print_status "Added enable_uart=1 to $config_file"
            fi
            ;;
    esac
    
    # Disable and mask serial/bluetooth services to free up ttyAMA0
    local services_to_disable=(
        "serial-getty@ttyAMA0.service"
        "hciuart.service"
        "bluealsa.service"
        "bluetooth.service"
    )
    for svc in "${services_to_disable[@]}"; do
        systemctl disable "$svc" 2>/dev/null || true
        systemctl mask "$svc" 2>/dev/null || true
    done
    print_status "Disabled and masked serial/bluetooth services"

    print_warning "UART configuration updated - reboot required"
}

# Download and install dvmhost binary
install_dvmhost() {
    local arch
    arch=$(detect_arch)
    
    print_status "Detected architecture: $arch"
    print_status "Downloading DVMHost binary..."

    local download_url="${DVMHOST_BINS_REPO}/dvmhost-${arch}.tar.xz"
    local temp_dir
    temp_dir=$(mktemp -d)
    
    # Download the binary archive
    if ! wget -q --show-progress -O "${temp_dir}/dvmhost.tar.xz" "$download_url"; then
        print_error "Failed to download DVMHost binary from $download_url"
        rm -rf "$temp_dir"
        exit 1
    fi

    print_status "Extracting DVMHost..."
    
    # Extract to temp directory first
    tar -xJf "${temp_dir}/dvmhost.tar.xz" -C "$temp_dir"

    # Find and copy the dvmhost binary
    if [[ -f "${temp_dir}/dvmhost" ]]; then
        cp "${temp_dir}/dvmhost" /opt/centrunk/dvmhost/
        chmod +x /opt/centrunk/dvmhost/dvmhost
        print_status "DVMHost binary installed to /opt/centrunk/dvmhost/dvmhost"
    else
        # Try to find it in a subdirectory
        local found_binary
        found_binary=$(find "$temp_dir" -name "dvmhost" -type f | head -1)
        if [[ -n "$found_binary" ]]; then
            cp "$found_binary" /opt/centrunk/dvmhost/
            chmod +x /opt/centrunk/dvmhost/dvmhost
            print_status "DVMHost binary installed to /opt/centrunk/dvmhost/dvmhost"
        else
            print_error "dvmhost binary not found in archive"
            rm -rf "$temp_dir"
            exit 1
        fi
    fi

    # Cleanup
    rm -rf "$temp_dir"

    # # Verify the binary works
    # if /opt/centrunk/dvmhost/dvmhost --version 2>/dev/null || /opt/centrunk/dvmhost/dvmhost -h 2>/dev/null; then
    #     print_status "DVMHost binary verified successfully"
    # else
    #     print_warning "Could not verify DVMHost binary (this may be normal)"
    # fi
}

# Device authorization flow — register, display code, poll, download config
setup_device_config() {
    if [[ "$SKIP_DEVICE_SETUP" == "true" ]]; then
        print_warning "Skipping device config setup (--skip-device-setup flag)"
        return
    fi

    # Always confirm before overwriting existing configs
    if [[ -f /opt/centrunk/configs/configCC.yml || -f /opt/centrunk/configs/configVC.yml ]]; then
        print_warning "Config files already exist in /opt/centrunk/configs/"
        read -p "Overwrite existing configuration with new download from myCTRS? (y/N) " -n 1 -r < /dev/tty
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_status "Keeping existing configuration"
            return
        fi
        print_warning "Existing configs will be overwritten"
    fi

    print_status "Starting device authorization flow..."
    print_status "CTRS server: ${CTRS_URL}"

    # 1. Register
    local register_response
    if ! register_response=$(curl -sf -X POST "${CTRS_URL}/api/device/register/"); then
        print_error "Failed to register device with ${CTRS_URL}/api/device/register/"
        exit 1
    fi

    local user_code device_secret verify_url poll_interval
    user_code=$(echo "$register_response" | jq -r '.user_code')
    device_secret=$(echo "$register_response" | jq -r '.device_secret')
    verify_url=$(echo "$register_response" | jq -r '.verification_url_complete')
    poll_interval=$(echo "$register_response" | jq -r '.poll_interval // 5')

    if [[ -z "$user_code" || "$user_code" == "null" ]]; then
        print_error "Invalid response from device registration"
        exit 1
    fi

    # 2. Display code and URL
    echo ""
    echo "======================================================"
    echo -e "  ${GREEN}DEVICE CODE:${NC}  ${YELLOW}${user_code}${NC}"
    echo ""
    echo -e "  Open this URL in a browser to authorize this device:"
    echo -e "  ${GREEN}${verify_url}${NC}"
    echo "======================================================"
    echo ""
    print_status "Waiting for authorization (code expires in 15 minutes)..."

    # 3. Poll until authorized
    while true; do
        local status
        if ! status=$(curl -sf \
            -H "Authorization: Bearer ${device_secret}" \
            "${CTRS_URL}/api/device/poll/${user_code}/" \
            | jq -r '.status'); then
            print_error "Failed to poll device status"
            exit 1
        fi

        case "$status" in
            authorized)
                print_status "Device authorized! Downloading configuration..."
                break
                ;;
            expired)
                print_error "Device code expired. Please re-run the installer."
                exit 1
                ;;
            consumed)
                print_error "Configuration was already downloaded. Please re-run the installer to get a new code."
                exit 1
                ;;
            pending)
                sleep "$poll_interval"
                ;;
            *)
                print_error "Unexpected status from server: $status"
                exit 1
                ;;
        esac
    done

    # 4. Download config ZIP (capture headers for NetBird setup key)
    local tmp_zip tmp_headers
    tmp_zip=$(mktemp /tmp/ctrs_config_XXXXXX.zip)
    tmp_headers=$(mktemp /tmp/ctrs_headers_XXXXXX)

    if ! curl -sf \
        -H "Authorization: Bearer ${device_secret}" \
        "${CTRS_URL}/api/device/download/${user_code}/" \
        -D "$tmp_headers" \
        -o "$tmp_zip"; then
        print_error "Failed to download configuration"
        rm -f "$tmp_zip" "$tmp_headers"
        exit 1
    fi

    # Extract NetBird setup key if present in response headers
    NETBIRD_SETUP_KEY=$(grep -i 'X-Netbird-Setup-Key' "$tmp_headers" 2>/dev/null | cut -d' ' -f2 | tr -d '\r\n' || true)
    rm -f "$tmp_headers"

    # 5. Extract to config directory
    if ! unzip -o "$tmp_zip" -d /opt/centrunk/configs/; then
        print_error "Failed to extract configuration files"
        rm -f "$tmp_zip"
        exit 1
    fi

    # 6. Cleanup
    rm -f "$tmp_zip"

    DEVICE_SETUP_COMPLETED=true
    print_status "Configuration files installed to /opt/centrunk/configs/"
}

# Connect to NetBird VPN using setup key from CTRS device flow
connect_netbird() {
    if [[ "$SKIP_NETBIRD" == "true" ]]; then
        return
    fi

    if [[ -z "${NETBIRD_SETUP_KEY:-}" ]]; then
        return
    fi

    # Tear down existing NetBird connection and config so the new key takes effect
    if systemctl is-active --quiet netbird 2>/dev/null || pgrep -x netbird >/dev/null 2>&1; then
        print_status "Stopping existing NetBird connection..."
        netbird down 2>/dev/null || true
    fi

    # Remove existing NetBird config so the new setup key is accepted cleanly
    if [[ -f /etc/netbird/config.json ]]; then
        print_status "Removing existing NetBird configuration..."
        rm -f /etc/netbird/config.json
    fi

    print_status "NetBird setup key received from CTRS, joining VPN..."
    if netbird up \
        --management-url https://netbird.centrunk.net \
        --allow-server-ssh \
        --setup-key "$NETBIRD_SETUP_KEY"; then
        print_status "NetBird connected successfully"
        NETBIRD_AUTO_CONNECTED=true
    else
        print_warning "NetBird connection failed - you can retry manually after reboot"
    fi
}

# Install systemd services
install_services() {
    if [[ "$SKIP_SERVICES" == "true" ]]; then
        print_warning "Skipping systemd service installation (--skip-services flag)"
        return
    fi

    print_status "Installing systemd services..."

    local tmp_dir
    tmp_dir=$(mktemp -d)

    local services=("centrunk.cc.service" "centrunk.vc.service")

    for svc in "${services[@]}"; do
        local url="${INSTALLER_REPO_RAW}/systemd/${svc}"
        print_status "Downloading ${svc}..."
        if ! curl -fsSL -o "${tmp_dir}/${svc}" "$url"; then
            print_error "Failed to download ${svc} from ${url}"
            rm -rf "$tmp_dir"
            exit 1
        fi
        cp "${tmp_dir}/${svc}" /etc/systemd/system/
        print_status "Installed ${svc}"
    done

    rm -rf "$tmp_dir"

    # Reload systemd
    systemctl daemon-reload

    # Enable services (but don't start - configs needed first)
    systemctl enable centrunk.cc.service 2>/dev/null || true
    systemctl enable centrunk.vc.service 2>/dev/null || true

    print_status "Systemd services installed and enabled"
    print_warning "Services are NOT started - please configure /opt/centrunk/configs/configCC.yml and configVC.yml first"
}

# Fix ownership of /opt/centrunk so the original user can read/write files
# (e.g. to drop configs in via SFTP without needing root)
fix_permissions() {
    if [[ "$REAL_USER" == "root" ]]; then
        print_warning "Running as root without sudo - skipping /opt/centrunk ownership change"
        return
    fi

    print_status "Setting ownership of /opt/centrunk to ${REAL_USER}..."
    chown -R "${REAL_USER}:" /opt/centrunk
    print_status "Ownership of /opt/centrunk set to ${REAL_USER}"
}

# Print installation summary
print_summary() {
    echo ""
    echo "======================================"
    echo -e "${GREEN}Installation Complete!${NC}"
    echo "======================================"
    echo ""
    echo -e "${GREEN}You may re-run this script as needed to repair your installation.${NC}"
    echo ""
    echo "DVMHost binary: /opt/centrunk/dvmhost/dvmhost"
    echo "Config directory: /opt/centrunk/configs/"
    echo "Log directory: /var/log/centrunk/"
    echo ""
    echo "Systemd services:"
    echo "  - centrunk.cc.service (Control Channel)"
    echo "  - centrunk.vc.service (Voice Channel)"
    echo ""
    echo "Next steps:"
    local step=1

    if [[ "$DEVICE_SETUP_COMPLETED" == "true" ]]; then
        echo -e "  ${step}. ${GREEN}Configuration files provisioned successfully${NC}"
        echo "     Location: /opt/centrunk/configs/"
    else
        echo "  ${step}. Create your configuration files:"
        echo "     - /opt/centrunk/configs/configCC.yml"
        echo "     - /opt/centrunk/configs/configVC.yml"
    fi
    step=$((step + 1))
    echo ""
    echo "  ${step}. Start the services:"
    echo "     sudo systemctl start centrunk.cc.service"
    echo "     sudo systemctl start centrunk.vc.service"
    step=$((step + 1))
    echo ""
    echo "  ${step}. Check service status:"
    echo "     sudo systemctl status centrunk.cc.service"
    echo "     sudo systemctl status centrunk.vc.service"
    step=$((step + 1))
    echo ""
    if [[ "$SKIP_NETBIRD" != "true" ]]; then
        if [[ "${NETBIRD_AUTO_CONNECTED}" == "true" ]]; then
            echo "  ${step}. Netbird Status:"
            echo "     Netbird connected automatically using CTRS setup key"
        elif [[ -n "${NETBIRD_SETUP_KEY:-}" ]]; then
            echo "  ${step}. Connect Netbird (auto-connect failed, retry manually):"
            echo "     sudo netbird up --management-url https://netbird.centrunk.net --allow-server-ssh --setup-key ${NETBIRD_SETUP_KEY}"
        elif [[ "${NETBIRD_ALREADY_RUNNING:-false}" == "true" ]]; then
            echo "  ${step}. Netbird Status:"
            echo "     Netbird was already running on this system"
            echo "     No configuration needed - using existing setup"
        else
            echo "  ${step}. Configure Netbird:"
            echo "     A setup key will be provided when you run device setup."
            echo "     Re-run this installer without --skip-device-setup to get one."
        fi
        echo ""
    fi
    echo -e "${RED}======================================${NC}"
    echo -e "${RED}  YOU MUST REBOOT BEFORE CONTINUING   ${NC}"
    echo -e "${RED}======================================${NC}"
    echo ""
    echo -e "  Run: ${GREEN}sudo reboot${NC}"
    echo ""
}

# Main installation flow
main() {
    echo "======================================"
    echo "Centrunk DVMHost Installation Script"
    echo "======================================"
    echo ""

    check_root
    check_platform
    install_prerequisites
    install_netbird
    create_directories
    clone_firmware
    build_firmware
    remove_console_params
    disable_bluetooth
    install_dvmhost
    setup_device_config
    connect_netbird
    install_services
    fix_permissions
    print_summary
}

# Run main function
main "$@"
