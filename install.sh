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
#     --skip-user-setup      Skip ctrs service account creation
#     --skip-osquery         Skip osquery endpoint monitoring installation
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

# Fleet osquery enrollment
FLEET_ENROLL_SECRET="73qNTG5UKGwt6VRb99F7o7JueQv3Iqqa"

# CTRS server URL (for device authorization flow)
CTRS_URL="${CTRS_URL:-https://my.centrunk.net}"

# Default options
SKIP_NETBIRD=false
SKIP_SERVICES=false
SKIP_FIRMWARE_BUILD=false
SKIP_PLATFORM_CHECK=false
SKIP_DEVICE_SETUP=false
SKIP_USER_SETUP=false
SKIP_OSQUERY=false
NON_INTERACTIVE=false
DEVICE_SETUP_COMPLETED=false
FIRMWARE_CHANGED=true
NETBIRD_SETUP_KEY=""
NETBIRD_AUTO_CONNECTED=false

# Step result tracking (set by each function, read by print_summary)
STATUS_PLATFORM=""
STATUS_PREREQUISITES=""
STATUS_NETBIRD_INSTALL=""
STATUS_DIRECTORIES=""
STATUS_FIRMWARE_CLONE=""
STATUS_FIRMWARE_BUILD=""
STATUS_CONSOLE_PARAMS=""
STATUS_BLUETOOTH=""
STATUS_DVMHOST=""
STATUS_DEVICE_SETUP=""
STATUS_NETBIRD_CONNECT=""
STATUS_SERVICES=""
STATUS_USER_SETUP=""
STATUS_HOSTNAME=""
STATUS_OSQUERY=""
STATUS_PERMISSIONS=""

# Determine the real (non-root) user who invoked this script.
# When run via `sudo`, SUDO_USER is the original user; fall back to $USER.
REAL_USER="${SUDO_USER:-$USER}"

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
        --skip-user-setup)
            SKIP_USER_SETUP=true
            shift
            ;;
        --skip-osquery)
            SKIP_OSQUERY=true
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
            echo "  --skip-user-setup      Skip ctrs service account creation"
            echo "  --skip-osquery         Skip osquery endpoint monitoring installation"
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

# Detect and stop any running Centrunk services before installation
stop_running_services() {
    local active_services
    active_services=$(systemctl list-units 'centrunk.*.service' --state=active --no-legend --no-pager 2>/dev/null | awk '{print $1}')

    if [[ -z "$active_services" ]]; then
        return
    fi

    print_warning "The following Centrunk services are currently running:"
    local svc
    for svc in $active_services; do
        echo -e "  ${YELLOW}-${NC} ${svc}"
    done
    echo ""

    if [[ "$NON_INTERACTIVE" != "true" ]]; then
        read -p "Stop these services and continue installation? (y/N) " -n 1 -r < /dev/tty
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_error "Cannot continue while services are running"
            exit 1
        fi
    else
        print_status "Non-interactive mode: stopping services automatically"
    fi

    for svc in $active_services; do
        print_status "Stopping ${svc}..."
        systemctl stop "$svc" 2>/dev/null || true
    done
    print_status "All Centrunk services stopped"
}

# Verify platform and architecture requirements
check_platform() {
    if [[ "$SKIP_PLATFORM_CHECK" == "true" ]]; then
        print_warning "Skipping platform verification (--skip-platform-check flag)"
        STATUS_PLATFORM="skipped"
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
        STATUS_PLATFORM="overridden"
    else
        print_status "Platform verification passed!"
        STATUS_PLATFORM="passed"
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
    STATUS_PREREQUISITES="done"
}

# Install osquery endpoint monitoring
install_osquery() {
    if [[ "$SKIP_OSQUERY" == "true" ]]; then
        print_warning "Skipping osquery installation (--skip-osquery flag)"
        STATUS_OSQUERY="skipped"
        return
    fi

    # Deploy configuration (even if already installed, keep config current)
    deploy_osquery_config() {
        local conf_url="${INSTALLER_REPO_RAW}/osquery/osquery.conf"
        local flags_url="${INSTALLER_REPO_RAW}/osquery/osquery.flags"

        print_status "Deploying osquery configuration..."
        mkdir -p /etc/osquery

        # Download JSON config (FIM paths)
        if ! curl -fsSL -o /etc/osquery/osquery.conf "$conf_url"; then
            print_warning "Failed to download osquery.conf, writing minimal default"
            cat > /etc/osquery/osquery.conf << 'OSQEOF'
{
  "file_paths": {
    "centrunk_configs": ["/opt/centrunk/configs/%%"],
    "centrunk_binaries": ["/opt/centrunk/dvmhost/dvmhost"]
  },
  "file_accesses": ["centrunk_configs", "centrunk_binaries"]
}
OSQEOF
        fi

        # Download flagfile (CLI flags for TLS/Fleet enrollment)
        if ! curl -fsSL -o /etc/osquery/osquery.flags "$flags_url"; then
            print_warning "Failed to download osquery.flags, writing minimal default"
            cat > /etc/osquery/osquery.flags << 'FLAGEOF'
--config_plugin=tls
--logger_plugin=tls
--logger_path=/var/log/osquery
--database_path=/var/osquery/osquery.db
--tls_hostname=fleet.tatrs.org
--enroll_secret_path=/etc/osquery/enroll_secret
--enroll_tls_endpoint=/api/osquery/enroll
--config_tls_endpoint=/api/v1/osquery/config
--logger_tls_endpoint=/api/v1/osquery/log
--distributed_plugin=tls
--distributed_tls_read_endpoint=/api/v1/osquery/distributed/read
--distributed_tls_write_endpoint=/api/v1/osquery/distributed/write
--tls_server_certs=/etc/ssl/certs/ca-certificates.crt
FLAGEOF
        fi

        # Write Fleet enroll secret
        echo "$FLEET_ENROLL_SECRET" > /etc/osquery/enroll_secret
        chmod 600 /etc/osquery/enroll_secret
    }

    # Idempotent: skip install if already present
    if command -v osqueryd &>/dev/null; then
        print_status "osquery already installed"
        deploy_osquery_config
        STATUS_OSQUERY="already installed"
        return
    fi

    print_status "Installing osquery..."

    # Import the osquery GPG signing key (modern signed-by approach)
    curl -fsSL https://pkg.osquery.io/deb/pubkey.gpg \
        | gpg --dearmor -o /usr/share/keyrings/osquery-archive-keyring.gpg

    # Add the official osquery apt repository
    local arch
    arch="$(dpkg --print-architecture)"
    echo "deb [arch=${arch} signed-by=/usr/share/keyrings/osquery-archive-keyring.gpg] https://pkg.osquery.io/deb deb main" \
        > /etc/apt/sources.list.d/osquery.list

    apt-get update -qq
    apt-get install -y osquery

    deploy_osquery_config

    # Enable and start the daemon immediately
    systemctl enable --now osqueryd

    print_status "osquery installed and running"
    STATUS_OSQUERY="installed"
}

# Install Netbird
install_netbird() {
    if [[ "$SKIP_NETBIRD" == "true" ]]; then
        print_warning "Skipping Netbird installation (--skip-netbird flag)"
        STATUS_NETBIRD_INSTALL="skipped"
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
        STATUS_NETBIRD_INSTALL="installed"
    else
        print_status "Netbird binary already installed"
        STATUS_NETBIRD_INSTALL="already installed"
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

    STATUS_DIRECTORIES="done"
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
                STATUS_FIRMWARE_CLONE="already up to date"
            else
                print_status "Firmware source updated"
                FIRMWARE_CHANGED=true
                STATUS_FIRMWARE_CLONE="updated"
            fi
        else
            print_warning "git pull failed - continuing with existing checkout"
            FIRMWARE_CHANGED=true
            STATUS_FIRMWARE_CLONE="pull failed, using existing"
        fi
        return
    fi

    print_status "Cloning dvmfirmware-hs..."
    if ! git clone --recurse-submodules https://github.com/DVMProject/dvmfirmware-hs.git "$dest"; then
        print_error "Failed to clone dvmfirmware-hs"
        exit 1
    fi
    FIRMWARE_CHANGED=true
    STATUS_FIRMWARE_CLONE="cloned"
    print_status "dvmfirmware-hs cloned to $dest"
}

# Build firmware for MMDVM_HS_Hat (dual)
build_firmware() {
    if [[ "$SKIP_FIRMWARE_BUILD" == "true" ]]; then
        print_warning "Skipping firmware build (--skip-firmware-build flag)"
        STATUS_FIRMWARE_BUILD="skipped"
        return
    fi

    if [[ "$FIRMWARE_CHANGED" != "true" ]]; then
        print_status "Firmware source unchanged - skipping rebuild"
        STATUS_FIRMWARE_BUILD="skipped (source unchanged)"
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
    STATUS_FIRMWARE_BUILD="built"
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
        STATUS_CONSOLE_PARAMS="cleaned"
    else
        STATUS_CONSOLE_PARAMS="not needed"
    fi
}

# Disable Bluetooth to free up ttyAMA0
disable_bluetooth() {
    local config_file="/boot/firmware/config.txt"
    if [[ ! -f "$config_file" ]]; then
        print_warning "No config.txt found - skipping Bluetooth disable"
        STATUS_BLUETOOTH="skipped (no config.txt)"
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
        STATUS_BLUETOOTH="skipped (unknown model)"
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
    STATUS_BLUETOOTH="configured (${pi_model})"
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
        STATUS_DVMHOST="installed"
    else
        # Try to find it in a subdirectory
        local found_binary
        found_binary=$(find "$temp_dir" -name "dvmhost" -type f | head -1)
        if [[ -n "$found_binary" ]]; then
            cp "$found_binary" /opt/centrunk/dvmhost/
            chmod +x /opt/centrunk/dvmhost/dvmhost
            print_status "DVMHost binary installed to /opt/centrunk/dvmhost/dvmhost"
            STATUS_DVMHOST="installed"
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
        STATUS_DEVICE_SETUP="skipped"
        return
    fi

    # All possible config files that any site type might have
    local all_configs=(
        "configCC.yml"
        "configVC.yml"
        "configDVRS.yml"
        "configCONVENTIONAL.yml"
    )

    # Always confirm before overwriting existing configs
    local has_existing=false
    for cfg in "${all_configs[@]}"; do
        if [[ -f "/opt/centrunk/configs/${cfg}" ]]; then
            has_existing=true
            break
        fi
    done

    if [[ "$has_existing" == "true" ]]; then
        print_warning "Config files already exist in /opt/centrunk/configs/"
        read -p "Overwrite existing configuration with new download from myCTRS? (y/N) " -n 1 -r < /dev/tty
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_status "Keeping existing configuration"
            STATUS_DEVICE_SETUP="kept existing"
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

    # 5. Clear existing configs and extract new ones
    rm -rf /opt/centrunk/configs/*
    if ! unzip -o "$tmp_zip" -d /opt/centrunk/configs/; then
        print_error "Failed to extract configuration files"
        rm -f "$tmp_zip"
        exit 1
    fi

    # 6. Cleanup
    rm -f "$tmp_zip"

    DEVICE_SETUP_COMPLETED=true
    STATUS_DEVICE_SETUP="provisioned"
    print_status "Configuration files installed to /opt/centrunk/configs/"
}

# Set system hostname to ctrs-RFSS-SITE based on device config
set_hostname() {
    local config_file="/opt/centrunk/configs/configCC.yml"

    if [[ ! -f "$config_file" ]]; then
        print_warning "configCC.yml not found, skipping hostname configuration"
        STATUS_HOSTNAME="no config"
        return
    fi

    local rfss_id site_id
    rfss_id=$(grep 'rfssId:' "$config_file" | awk '{print $2}' | tr -d '\r\n')
    site_id=$(grep 'siteId:' "$config_file" | awk '{print $2}' | tr -d '\r\n')

    if [[ -z "$rfss_id" || -z "$site_id" ]]; then
        print_warning "Could not parse rfssId/siteId from configCC.yml, skipping hostname"
        STATUS_HOSTNAME="missing config values"
        return
    fi

    local new_hostname="ctrs-${rfss_id}-${site_id}"
    local old_hostname
    old_hostname=$(hostname)

    if [[ "$old_hostname" == "$new_hostname" ]]; then
        print_status "Hostname already set to ${new_hostname}"
        STATUS_HOSTNAME="${new_hostname}"
        return
    fi

    hostnamectl set-hostname "$new_hostname"
    # Update /etc/hosts: replace old hostname with new, or add entry
    if grep -q "$old_hostname" /etc/hosts; then
        sed -i "s/${old_hostname}/${new_hostname}/g" /etc/hosts
    elif ! grep -q "$new_hostname" /etc/hosts; then
        sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${new_hostname}/" /etc/hosts
    fi

    print_status "Hostname set to ${new_hostname}"
    STATUS_HOSTNAME="${new_hostname}"
}

# Connect to NetBird VPN using setup key from CTRS device flow
connect_netbird() {
    if [[ "$SKIP_NETBIRD" == "true" ]]; then
        STATUS_NETBIRD_CONNECT="skipped"
        return
    fi

    if [[ -z "${NETBIRD_SETUP_KEY:-}" ]]; then
        STATUS_NETBIRD_CONNECT="no setup key"
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

    if [[ ! "$STATUS_HOSTNAME" =~ ^ctrs- ]]; then
        print_error "Cannot connect to NetBird without a valid hostname (ctrs-RFSS-SITE)"
        STATUS_NETBIRD_CONNECT="no hostname"
        return 1
    fi

    print_status "NetBird setup key received from CTRS, joining VPN..."
    if netbird up \
        --management-url https://netbird.centrunk.net \
        --allow-server-ssh \
        --setup-key "$NETBIRD_SETUP_KEY" \
        --hostname "$STATUS_HOSTNAME"; then
        print_status "NetBird connected successfully"
        NETBIRD_AUTO_CONNECTED=true
        STATUS_NETBIRD_CONNECT="connected"
    else
        print_warning "NetBird connection failed - you can retry manually after reboot"
        STATUS_NETBIRD_CONNECT="failed"
    fi
}

# Install systemd services
install_services() {
    if [[ "$SKIP_SERVICES" == "true" ]]; then
        print_warning "Skipping systemd service installation (--skip-services flag)"
        STATUS_SERVICES="skipped"
        return
    fi

    print_status "Installing systemd services..."

    # All possible service units for any site type
    local all_services=(
        "centrunk.cc.service"
        "centrunk.vc.service"
        "centrunk.dvrs.service"
        "centrunk.conv.service"
    )

    # Stop, disable, and remove all known services regardless of site type
    for svc_name in "${all_services[@]}"; do
        if [[ -f "/etc/systemd/system/${svc_name}" ]]; then
            print_status "Removing existing ${svc_name}..."
            systemctl stop "$svc_name" 2>/dev/null || true
            systemctl disable "$svc_name" 2>/dev/null || true
            rm -f "/etc/systemd/system/${svc_name}"
        fi
    done

    # Also catch any unexpected centrunk services not in the known list
    for svc_file in /etc/systemd/system/centrunk.*.service; do
        [[ -e "$svc_file" ]] || continue
        local svc_name
        svc_name=$(basename "$svc_file")
        print_status "Removing unexpected ${svc_name}..."
        systemctl stop "$svc_name" 2>/dev/null || true
        systemctl disable "$svc_name" 2>/dev/null || true
        rm -f "$svc_file"
    done
    systemctl daemon-reload

    # Map config files to their corresponding service units
    local -A config_to_service=(
        ["configCC.yml"]="centrunk.cc.service"
        ["configVC.yml"]="centrunk.vc.service"
        ["configDVRS.yml"]="centrunk.dvrs.service"
        ["configCONVENTIONAL.yml"]="centrunk.conv.service"
    )

    # Determine which services to install based on configs present
    local services=()
    for config in "${!config_to_service[@]}"; do
        if [[ -f "/opt/centrunk/configs/${config}" ]]; then
            services+=("${config_to_service[$config]}")
        fi
    done

    if [[ ${#services[@]} -eq 0 ]]; then
        print_warning "No config files found in /opt/centrunk/configs/ — skipping service installation"
        STATUS_SERVICES="no configs found"
        return
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d)

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

    # Reload systemd and enable+start services
    systemctl daemon-reload

    for svc in "${services[@]}"; do
        systemctl enable --now "$svc" 2>/dev/null || true
    done

    STATUS_SERVICES="installed (${#services[@]} services)"
    print_status "Systemd services installed, enabled, and started"
}

# Create the ctrs service account for Ansible automation access.
# Sets up: user, passwordless sudo, SSH public key, sshd Match block.
setup_ctrs_user() {
    if [[ "$SKIP_USER_SETUP" == "true" ]]; then
        print_warning "Skipping ctrs user setup (--skip-user-setup)"
        STATUS_USER_SETUP="skipped"
        return
    fi

    print_status "Setting up ctrs service account..."

    # If ctrs user already exists, skip consent and just refresh the SSH key
    if id -u ctrs &>/dev/null; then
        print_status "User 'ctrs' already exists — updating SSH key"
    else
        # Consent prompt for new user creation
        echo ""
        echo "======================================"
        echo "  Service Account Setup (Recommended)"
        echo "======================================"
        echo ""
        echo "This step will create a user on your system with a username of 'ctrs'."
        echo "This user will have full sudo/root access, can only log in via ssh with"
        echo "public/private key authentication."
        echo ""
        echo "We use this user account for automation (such as software updates and"
        echo "configuration changes), as well as statistics gathering."
        echo ""
        echo "This account will have full access to your site. We will make best effort"
        echo "to ensure security, and we recommend putting your site in a DMZ or other"
        echo "VLAN that does not have access to the rest of your internal network."
        echo ""
        echo "This step is not required, but is strongly recommended."
        echo ""

        if [[ "$NON_INTERACTIVE" == "true" ]]; then
            print_status "Non-interactive mode: auto-accepting service account terms"
        else
            read -p "Do you accept and agree to create this account? (y/N) " -n 1 -r < /dev/tty
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                print_warning "Skipping ctrs service account setup (declined by user)"
                STATUS_USER_SETUP="skipped (declined)"
                return
            fi
        fi

        useradd -r -m -s /bin/bash ctrs
        print_status "Created user 'ctrs'"
    fi

    # 2. Passwordless sudo
    local sudoers_file="/etc/sudoers.d/ctrs"
    echo "ctrs ALL=(ALL) NOPASSWD: ALL" > "$sudoers_file"
    chmod 0440 "$sudoers_file"
    if visudo -cf "$sudoers_file" &>/dev/null; then
        print_status "Configured passwordless sudo for ctrs"
    else
        print_error "Sudoers validation failed — removing broken file"
        rm -f "$sudoers_file"
        STATUS_USER_SETUP="failed (sudoers)"
        return
    fi

    # 3. SSH authorized key
    local ctrs_home
    ctrs_home="$(eval echo ~ctrs)"
    local ssh_dir="${ctrs_home}/.ssh"

    mkdir -p "$ssh_dir"
    chmod 0700 "$ssh_dir"

    print_status "Downloading ctrs public key..."
    if ! curl -fsSL "${INSTALLER_REPO_RAW}/keys/ctrs.pub" -o "${ssh_dir}/authorized_keys"; then
        print_error "Failed to download ctrs public key"
        STATUS_USER_SETUP="failed (key download)"
        return
    fi

    chmod 0600 "${ssh_dir}/authorized_keys"
    chown -R ctrs:ctrs "$ssh_dir"
    print_status "Installed SSH authorized key for ctrs"

    # 4. Lock password authentication for ctrs
    passwd -l ctrs &>/dev/null
    print_status "Locked password for ctrs user"

    # Add sshd Match block if not already present
    local sshd_config="/etc/ssh/sshd_config"
    if ! grep -q "^Match User ctrs" "$sshd_config" 2>/dev/null; then
        {
            echo ""
            echo "# Centrunk service account — key-only authentication"
            echo "Match User ctrs"
            echo "    PasswordAuthentication no"
            echo "    AuthenticationMethods publickey"
        } >> "$sshd_config"
        print_status "Added sshd Match block for ctrs (key-only auth)"

        # Restart sshd to apply
        if systemctl is-active --quiet sshd 2>/dev/null; then
            systemctl restart sshd
            print_status "Restarted sshd"
        elif systemctl is-active --quiet ssh 2>/dev/null; then
            systemctl restart ssh
            print_status "Restarted ssh"
        fi
    else
        print_status "sshd Match block for ctrs already present"
    fi

    STATUS_USER_SETUP="configured"
}

# Fix ownership of /opt/centrunk so the original user can read/write files
# (e.g. to drop configs in via SFTP without needing root)
fix_permissions() {
    if [[ "$REAL_USER" == "root" ]]; then
        print_warning "Running as root without sudo - skipping /opt/centrunk ownership change"
        STATUS_PERMISSIONS="skipped (root user)"
        return
    fi

    print_status "Setting ownership of /opt/centrunk to ${REAL_USER}..."
    chown -R "${REAL_USER}:" /opt/centrunk
    print_status "Ownership of /opt/centrunk set to ${REAL_USER}"
    STATUS_PERMISSIONS="set (${REAL_USER})"
}

# Helper to print a status line with colored indicator
# Usage: print_step "Label" "status_string"
# Green checkmark for completed actions, yellow dash for skipped, red X for failures
print_step() {
    local label="$1"
    local status="$2"

    case "$status" in
        skipped*|no\ *|not\ needed|kept\ existing)
            printf "  ${YELLOW}[-]${NC} %-24s %s\n" "$label" "$status"
            ;;
        failed*|pull\ failed*)
            printf "  ${RED}[X]${NC} %-24s %s\n" "$label" "$status"
            ;;
        "")
            printf "  ${YELLOW}[-]${NC} %-24s %s\n" "$label" "n/a"
            ;;
        *)
            printf "  ${GREEN}[+]${NC} %-24s %s\n" "$label" "$status"
            ;;
    esac
}

# Print installation summary
print_summary() {
    echo ""
    echo "======================================"
    echo -e "${GREEN}  Installation Complete!${NC}"
    echo "======================================"
    echo ""

    echo "Actions Performed:"
    print_step "Platform check"       "$STATUS_PLATFORM"
    print_step "Prerequisites"        "$STATUS_PREREQUISITES"
    print_step "Osquery monitoring"   "$STATUS_OSQUERY"
    print_step "Netbird install"      "$STATUS_NETBIRD_INSTALL"
    print_step "Directory structure"  "$STATUS_DIRECTORIES"
    print_step "Firmware source"      "$STATUS_FIRMWARE_CLONE"
    print_step "Firmware build"       "$STATUS_FIRMWARE_BUILD"
    print_step "Console params"       "$STATUS_CONSOLE_PARAMS"
    print_step "Bluetooth/UART"       "$STATUS_BLUETOOTH"
    print_step "DVMHost binary"       "$STATUS_DVMHOST"
    print_step "Device config"        "$STATUS_DEVICE_SETUP"
    print_step "Hostname"              "$STATUS_HOSTNAME"
    print_step "Netbird VPN"          "$STATUS_NETBIRD_CONNECT"
    print_step "Systemd services"     "$STATUS_SERVICES"
    print_step "Service account"      "$STATUS_USER_SETUP"
    print_step "File permissions"     "$STATUS_PERMISSIONS"
    echo ""

    echo "Key Paths:"
    echo "  Binary:   /opt/centrunk/dvmhost/dvmhost"
    echo "  Configs:  /opt/centrunk/configs/"
    echo "  Logs:     /var/log/centrunk/"
    echo ""

    # Conditional next-steps section
    local has_next_steps=false

    if [[ "$STATUS_DEVICE_SETUP" != "provisioned" && "$STATUS_DEVICE_SETUP" != "kept existing" ]]; then
        has_next_steps=true
    fi
    if [[ "$STATUS_NETBIRD_CONNECT" == "failed" && -n "${NETBIRD_SETUP_KEY:-}" ]]; then
        has_next_steps=true
    fi
    if [[ "$STATUS_NETBIRD_CONNECT" == "no setup key" && "$SKIP_NETBIRD" != "true" && "${NETBIRD_ALREADY_RUNNING:-false}" != "true" ]]; then
        has_next_steps=true
    fi

    if [[ "$has_next_steps" == "true" ]]; then
        echo "Next Steps:"
        if [[ "$STATUS_DEVICE_SETUP" != "provisioned" && "$STATUS_DEVICE_SETUP" != "kept existing" ]]; then
            echo "  - Create your configuration files:"
            echo "      /opt/centrunk/configs/configCC.yml"
            echo "      /opt/centrunk/configs/configVC.yml"
        fi
        if [[ "$STATUS_NETBIRD_CONNECT" == "failed" && -n "${NETBIRD_SETUP_KEY:-}" ]]; then
            echo "  - Netbird auto-connect failed. Retry manually:"
            echo "      sudo netbird up --management-url https://netbird.centrunk.net --allow-server-ssh --setup-key ${NETBIRD_SETUP_KEY}"
        fi
        if [[ "$STATUS_NETBIRD_CONNECT" == "no setup key" && "$SKIP_NETBIRD" != "true" && "${NETBIRD_ALREADY_RUNNING:-false}" != "true" ]]; then
            echo "  - Configure Netbird: re-run installer without --skip-device-setup to get a setup key"
        fi
        echo ""
    fi

    echo -e "${GREEN}You may re-run this script as needed to repair your installation.${NC}"
    echo ""
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
    setup_ctrs_user
    stop_running_services
    install_prerequisites
    install_osquery
    install_netbird
    create_directories
    clone_firmware
    build_firmware
    remove_console_params
    disable_bluetooth
    install_dvmhost
    setup_device_config
    set_hostname
    connect_netbird
    install_services
    fix_permissions
    print_summary
}

# Run main function
main "$@"
