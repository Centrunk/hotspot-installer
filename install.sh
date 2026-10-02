#!/bin/bash
#
# Centrunk DVMHost Installation Script
# Automates installation on Raspberry Pi OS Bookworm/Trixie or Debian Trixie
# (64-bit aarch64/x86_64). Minimum 4GB RAM.
#
# Usage: sudo ./install.sh [options]
#   Options:
#     --skip-netbird         Skip Netbird installation
#     --skip-services        Skip systemd service installation
#     --skip-firmware-build  Skip firmware compilation
#     --skip-platform-check  Skip platform verification (for testing)
#     --skip-device-setup    Skip device authorization config provisioning
#     --skip-user-setup      Skip ctrs service account creation
#     --skip-upgrade         Skip the full package upgrade
#     --ctrs-url <url>       CTRS server URL (default: https://my.centrunk.net)
#     --claim-token-file <path>  myCTRS claim token file (headless pairing)
#     -y, --yes              Non-interactive mode (assume yes to prompts)
#     --help                 Show this help message
#
# One-liner installation:
#   curl -fsSL https://raw.githubusercontent.com/Centrunk/hotspot-installer/main/install.sh | sudo bash
#

set -e  # Exit on any error

# Never let apt/dpkg block on a debconf prompt - this script also runs unattended
# via the piped one-liner, where there is no terminal to answer one.
export DEBIAN_FRONTEND=noninteractive

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Installer build timestamp. Auto-updated by .githooks/pre-commit on every commit.
# Do not edit this line by hand — see .githooks/pre-commit and README.md.
INSTALLER_VERSION="2026-10-02 03:59:56 UTC"

# Binary download URL
DVMHOST_BINS_REPO="https://github.com/Centrunk/dvmbins/raw/master"

# Installer repo (for downloading service files, etc. when running via pipe)
INSTALLER_REPO_RAW="https://raw.githubusercontent.com/Centrunk/hotspot-installer/main"

# CTRS server URL (for device authorization flow)
CTRS_URL="${CTRS_URL:-https://my.centrunk.net}"

# Where the CTRS-assigned device name is cached between runs. Deliberately outside
# /opt/centrunk/configs/, which remove_existing_install wipes on every re-provision.
NETBIRD_HOSTNAME_FILE="/opt/centrunk/netbird-hostname"

# Optional myCTRS claim token file (headless pairing). The token routes this device
# into its owner's "Waiting devices" queue; it never authorizes anything by itself.
CTRS_CLAIM_TOKEN_FILE="${CTRS_CLAIM_TOKEN_FILE:-}"
CLAIM_TOKEN=""

# Default options
SKIP_NETBIRD=false
SKIP_SERVICES=false
SKIP_FIRMWARE_BUILD=false
SKIP_PLATFORM_CHECK=false
SKIP_DEVICE_SETUP=false
SKIP_USER_SETUP=false
SKIP_UPGRADE=false
NON_INTERACTIVE=false
DEVICE_SETUP_COMPLETED=false
FIRMWARE_CHANGED=true
NETBIRD_SETUP_KEY=""
NETBIRD_HOSTNAME=""
NETBIRD_AUTO_CONNECTED=false

# Step result tracking (set by each function, read by print_summary)
STATUS_PLATFORM=""
STATUS_MEMORY=""
STATUS_PREREQUISITES=""
STATUS_UPGRADE=""
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
STATUS_OSQUERY_REMOVE=""
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
        --skip-upgrade)
            SKIP_UPGRADE=true
            shift
            ;;
        --ctrs-url)
            CTRS_URL="$2"
            shift 2
            ;;
        --claim-token-file)
            CTRS_CLAIM_TOKEN_FILE="$2"
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
            echo "  --skip-upgrade         Skip the full package upgrade"
            echo "  --ctrs-url <url>       CTRS server URL (default: https://my.centrunk.net)"
            echo "  --claim-token-file <path>"
            echo "                         myCTRS claim token file for headless pairing"
            echo "                         (or set CTRS_CLAIM_TOKEN_FILE)"
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
    
    # Check architecture - 64-bit ARM (aarch64) or 64-bit x86 (x86_64)
    local arch
    arch=$(uname -m)
    case "$arch" in
        aarch64|x86_64)
            print_status "Architecture: $arch ✓"
            ;;
        *)
            print_error "This installer requires 64-bit ARM (aarch64) or 64-bit x86 (x86_64)"
            print_error "Detected architecture: $arch"
            errors=$((errors + 1))
            ;;
    esac
    
    # Check OS release file exists
    if [[ ! -f /etc/os-release ]]; then
        print_error "Cannot detect OS - /etc/os-release not found"
        exit 1
    fi
    
    # shellcheck source=/dev/null
    . /etc/os-release
    
    # Detect the OS family. Two supported platforms:
    #   - Raspberry Pi OS (sets ID=debian but has "Raspberry Pi" in PRETTY_NAME,
    #     and ships /etc/rpi-issue; older releases use ID=raspbian)
    #   - Generic Debian (ID=debian, no Raspberry Pi markers)
    local is_rpi_os=false
    if [[ -f /etc/rpi-issue ]]; then
        is_rpi_os=true
    elif [[ "$PRETTY_NAME" == *"Raspberry Pi"* ]]; then
        is_rpi_os=true
    elif [[ "$ID" == "raspbian" ]]; then
        is_rpi_os=true
    fi

    local is_debian=false
    if [[ "$ID" == "debian" ]]; then
        is_debian=true
    fi

    if [[ "$is_rpi_os" == "true" ]]; then
        print_status "Operating System: Raspberry Pi OS ✓"
    elif [[ "$is_debian" == "true" ]]; then
        print_status "Operating System: Debian ✓"
    else
        print_error "This installer requires Raspberry Pi OS or Debian"
        print_error "Detected OS: $PRETTY_NAME"
        errors=$((errors + 1))
    fi

    # Codename check. Raspberry Pi OS allows Bookworm or Trixie; generic Debian
    # is supported on Trixie only. Anything else is rejected.
    if [[ "$is_rpi_os" == "true" ]]; then
        if [[ "$VERSION_CODENAME" != "bookworm" && "$VERSION_CODENAME" != "trixie" ]]; then
            print_error "This installer requires Raspberry Pi OS Bookworm or Trixie"
            print_error "Detected version: $VERSION_CODENAME"
            errors=$((errors + 1))
        else
            print_status "Version: $VERSION_CODENAME ✓"
        fi
    elif [[ "$is_debian" == "true" ]]; then
        if [[ "$VERSION_CODENAME" != "trixie" ]]; then
            print_error "This installer requires Debian Trixie"
            print_error "Detected version: $VERSION_CODENAME"
            errors=$((errors + 1))
        else
            print_status "Version: $VERSION_CODENAME ✓"
        fi
    fi
    
    # Check for 64-bit OS (not just 64-bit CPU)
    local os_arch
    os_arch=$(getconf LONG_BIT)
    if [[ "$os_arch" != "64" ]]; then
        print_error "This installer requires a 64-bit OS"
        print_error "Detected: ${os_arch}-bit OS"
        errors=$((errors + 1))
    else
        print_status "OS Architecture: 64-bit ✓"
    fi
    
    # Exit if any checks failed
    if [[ $errors -gt 0 ]]; then
        echo ""
        print_error "Platform verification failed with $errors error(s)"
        print_error "This installer requires: Raspberry Pi OS (Bookworm/Trixie) or Debian Trixie, 64-bit (aarch64/x86_64)"
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

# Verify the system has enough RAM (minimum 4GB). Treated as part of platform
# verification, so --skip-platform-check bypasses it too.
check_memory() {
    if [[ "$SKIP_PLATFORM_CHECK" == "true" ]]; then
        print_warning "Skipping memory verification (--skip-platform-check flag)"
        STATUS_MEMORY="skipped"
        return
    fi

    # Minimum required RAM. MemTotal excludes the GPU/CMA reservation and kernel
    # reserves, so a genuine 4GB Pi reports as little as ~3.45 GiB (256-512 MB
    # CMA with the KMS driver, or a legacy gpu_mem firmware split). The floor is
    # set at 3,400,000 kB (~3.24 GiB) to accept every 4GB configuration while
    # still rejecting 2GB hardware (~1.9 GiB).
    local min_kb=3400000

    local mem_kb
    mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)

    if [[ -z "$mem_kb" ]]; then
        print_warning "Could not determine system memory - skipping check"
        STATUS_MEMORY="skipped (undetectable)"
        return
    fi

    local mem_mb=$((mem_kb / 1024))

    if [[ "$mem_kb" -ge "$min_kb" ]]; then
        print_status "Memory: ${mem_mb} MB ✓"
        STATUS_MEMORY="passed"
        return
    fi

    echo ""
    print_warning "We *strongly* recommend a minimum of 4GB of RAM. Your system has less than that."
    print_warning "Detected: ${mem_mb} MB"
    echo ""
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        print_error "Non-interactive mode: aborting due to insufficient memory"
        print_error "Use --skip-platform-check to bypass this check"
        exit 1
    fi
    read -p "Continue anyway? (y/N) " -n 1 -r < /dev/tty
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
    print_warning "Continuing despite low memory - this may cause issues!"
    STATUS_MEMORY="low (overridden)"
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
        libnewlib-arm-none-eabi \
        gpg \
        sudo \
        ca-certificates \
        vim \
        libdw-dev

    print_status "Prerequisites installed successfully"
    STATUS_PREREQUISITES="done"
}

# Bring installed packages up to date. Uses `upgrade` rather than dist-upgrade so an
# unattended run can never remove a package a live hotspot depends on. The Dpkg
# options keep the on-disk version of any config file that has been modified.
upgrade_system() {
    if [[ "$SKIP_UPGRADE" == "true" ]]; then
        print_warning "Skipping package upgrade (--skip-upgrade flag)"
        STATUS_UPGRADE="skipped"
        return
    fi

    print_status "Upgrading installed packages (this may take a while)..."
    # Package lists were refreshed by install_prerequisites moments ago.
    if apt-get upgrade -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold"; then
        print_status "Packages upgraded"
        STATUS_UPGRADE="done"
    else
        print_warning "Package upgrade failed - continuing"
        STATUS_UPGRADE="failed"
    fi
}

# Remove osquery endpoint monitoring left behind by older installer versions.
# osquery is no longer part of this product; a re-run must clean it off devices
# that were provisioned by a previous release. No-op on a clean system.
remove_osquery() {
    local osquery_repo="/etc/apt/sources.list.d/osquery.list"
    local osquery_keyring="/usr/share/keyrings/osquery-archive-keyring.gpg"

    # Nothing to do unless the binary, the unit, or any leftover path is present
    if ! command -v osqueryd &>/dev/null \
        && ! systemctl list-unit-files osqueryd.service &>/dev/null \
        && [[ ! -e /etc/osquery && ! -e /var/osquery && ! -e "$osquery_repo" ]]; then
        STATUS_OSQUERY_REMOVE="not needed"
        return
    fi

    print_status "Removing osquery (no longer used by Centrunk)..."

    systemctl stop osqueryd &>/dev/null || true
    systemctl disable osqueryd &>/dev/null || true

    # Purge rather than remove so packaged conffiles go too
    apt-get purge -y osquery &>/dev/null || true

    # Drops the Fleet enroll secret and the local osquery database/logs
    rm -rf /etc/osquery /var/osquery /var/log/osquery

    # Remove the apt repo so later apt-get runs don't fail on an unreachable source
    rm -f "$osquery_repo" "$osquery_keyring"
    apt-get update -qq || true

    print_status "osquery removed"
    STATUS_OSQUERY_REMOVE="removed"
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

# Remove all existing centrunk configs and systemd service units.
# Called only after a new config ZIP has been successfully downloaded from CTRS,
# so we never wipe a working install without a replacement in hand.
remove_existing_install() {
    print_status "Removing existing centrunk.*.service units..."
    shopt -s nullglob
    for svc_file in /etc/systemd/system/centrunk.*.service; do
        local svc_name
        svc_name=$(basename "$svc_file")
        systemctl stop "$svc_name" 2>/dev/null || true
        systemctl disable "$svc_name" 2>/dev/null || true
        rm -f "$svc_file"
        print_status "  Removed ${svc_name}"
    done
    shopt -u nullglob
    systemctl daemon-reload

    print_status "Clearing /opt/centrunk/configs/..."
    rm -rf /opt/centrunk/configs/*
}

# Read the optional myCTRS claim token. Done early so a bad token file fails in
# seconds, not after the firmware build. The token is never echoed.
load_claim_token() {
    if [[ -z "$CTRS_CLAIM_TOKEN_FILE" || "$SKIP_DEVICE_SETUP" == "true" ]]; then
        return
    fi

    if [[ ! -f "$CTRS_CLAIM_TOKEN_FILE" || ! -r "$CTRS_CLAIM_TOKEN_FILE" ]]; then
        print_error "Claim token file is missing or unreadable: ${CTRS_CLAIM_TOKEN_FILE}"
        exit 1
    fi

    CLAIM_TOKEN=$(tr -d '[:space:]' < "$CTRS_CLAIM_TOKEN_FILE")
    if [[ -z "$CLAIM_TOKEN" ]]; then
        print_error "Claim token file is empty: ${CTRS_CLAIM_TOKEN_FILE}"
        exit 1
    fi
    # myCTRS issues URL-safe base64; anything else is a corrupt or wrong file.
    if [[ ! "$CLAIM_TOKEN" =~ ^[A-Za-z0-9_-]+$ ]]; then
        CLAIM_TOKEN=""
        print_error "Claim token file does not contain a valid token: ${CTRS_CLAIM_TOKEN_FILE}"
        exit 1
    fi
    print_status "Claim token loaded from ${CTRS_CLAIM_TOKEN_FILE}"
}

# JSON body for a claimed registration, written to stdout. printf is a shell
# builtin, so the token never appears on any process's command line.
# jq is installed by install_prerequisites before this runs.
build_claim_body() {
    printf '%s' "$CLAIM_TOKEN" | jq -jRc '{claim_token: .}'
}

# Fatal: the server rejected the claim token (HTTP 410) or did not honor it.
# Exiting ends the loop - the first-boot service caps its retries.
claim_token_invalid() {
    print_error "Claim token is no longer valid (expired, revoked or already used). Mint a new one in myCTRS and re-flash the card."
    exit 1
}

# curl wrapper for the myCTRS device API. Prints the response body followed by a
# final line holding the HTTP status (000 when curl could not get a response).
# Deliberately no -f, so callers can tell a rate limit from an outage.
ctrs_http() {
    curl -s -w '\n%{http_code}' "$@" || true
}

# Worth retrying: no response at all, rate limited (django-ratelimit answers 403),
# or a server-side error.
is_transient_http() {
    case "$1" in
        000|403|429|5??) return 0 ;;
        *) return 1 ;;
    esac
}

# Exponential backoff, capped at 60s
next_backoff() {
    local next=$(( $1 * 2 ))
    if (( next > 60 )); then
        next=60
    fi
    echo "$next"
}

# Headless pairing with a claim token: register with the token, then poll until the
# owner approves the device in myCTRS. Only used when a claim token is loaded; a run
# without one uses the original interactive flow unchanged. Rides out code expiry and
# transient server or network failures instead of exiting, since nobody is at the
# console. Assigns user_code and device_secret in the caller's scope.
claim_token_pairing() {
    local response http_code body backoff status claimed poll_interval reregister

    # Outer loop: one iteration per registration. Only "authorized" leaves it.
    while true; do
        # 1. Register (token goes in via stdin, never argv, so it cannot show up in ps)
        backoff=5
        while true; do
            response=$(build_claim_body | ctrs_http -X POST \
                -H "Content-Type: application/json" \
                --data-binary @- \
                "${CTRS_URL}/api/device/register/")
            http_code="${response##*$'\n'}"
            body="${response%$'\n'*}"

            if [[ "$http_code" == 2?? ]]; then
                break
            fi
            if [[ "$http_code" == "410" ]]; then
                claim_token_invalid
            fi
            if is_transient_http "$http_code"; then
                print_warning "Device registration failed (HTTP ${http_code}) - retrying in ${backoff}s..."
                sleep "$backoff"
                backoff=$(next_backoff "$backoff")
                continue
            fi
            print_error "Failed to register device with ${CTRS_URL}/api/device/register/ (HTTP ${http_code})"
            exit 1
        done

        user_code=$(echo "$body" | jq -r '.user_code')
        device_secret=$(echo "$body" | jq -r '.device_secret')
        poll_interval=$(echo "$body" | jq -r '.poll_interval // 5')
        claimed=$(echo "$body" | jq -r '.claimed // false')
        [[ "$poll_interval" =~ ^[0-9]+$ ]] || poll_interval=5

        if [[ -z "$user_code" || "$user_code" == "null" ]]; then
            print_error "Invalid response from device registration"
            exit 1
        fi
        # A token the server did not honor is fatal: re-registering would only
        # ever produce an unclaimed code nobody is watching for.
        if [[ "$claimed" != "true" ]]; then
            claim_token_invalid
        fi

        # 2. Display code and where to approve it
        echo ""
        echo "======================================================"
        echo -e "  ${GREEN}DEVICE CODE:${NC}  ${YELLOW}${user_code}${NC}"
        echo ""
        echo -e "  This device is claimed — approve it at ${CTRS_URL%/}/device/claims/"
        echo "======================================================"
        echo ""
        print_status "Waiting for approval in myCTRS..."

        # 3. Poll until authorized
        backoff=5
        reregister=false
        while true; do
            response=$(ctrs_http \
                -H "Authorization: Bearer ${device_secret}" \
                "${CTRS_URL}/api/device/poll/${user_code}/")
            http_code="${response##*$'\n'}"
            body="${response%$'\n'*}"

            if [[ "$http_code" != 2?? ]]; then
                if is_transient_http "$http_code"; then
                    print_warning "Failed to poll device status (HTTP ${http_code}) - retrying in ${backoff}s..."
                    sleep "$backoff"
                    backoff=$(next_backoff "$backoff")
                    continue
                fi
                # 401/404: the server no longer knows this code. Start over.
                print_warning "Device code rejected by server (HTTP ${http_code}) - registering again..."
                reregister=true
                break
            fi
            backoff=5

            status=$(echo "$body" | jq -r '.status' 2>/dev/null || true)
            case "$status" in
                authorized)
                    print_status "Device authorized! Downloading configuration..."
                    break
                    ;;
                expired)
                    print_warning "Device code expired - registering again..."
                    reregister=true
                    break
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

        if [[ "$reregister" != "true" ]]; then
            return 0
        fi
    done
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
        if [[ -n "$CLAIM_TOKEN" ]]; then
            # Headless (claim token) runs have no terminal to ask, and must never
            # wipe a working install on their own.
            print_status "Claim token in use: keeping existing configuration and services (skipping re-pairing)"
            STATUS_DEVICE_SETUP="kept existing"
            return
        fi
        print_warning "Existing centrunk.*.service units will also be removed."
        read -p "Overwrite existing configuration and services with a fresh download from myCTRS? (y/N) " -n 1 -r < /dev/tty
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_status "Keeping existing configuration and services"
            STATUS_DEVICE_SETUP="kept existing"
            return
        fi
        print_warning "Existing configs and services will be removed once new configs are downloaded"
    fi

    print_status "Starting device authorization flow..."
    print_status "CTRS server: ${CTRS_URL}"

    if [[ -n "$CLAIM_TOKEN" ]]; then
        # Headless pairing; sets user_code and device_secret in this scope.
        local user_code device_secret
        claim_token_pairing
    else
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
    fi

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
    # The server is the source of truth for this device's name (hs-<rid4>-<rfss>-<site_hex>)
    NETBIRD_HOSTNAME=$(grep -i 'X-Netbird-Hostname' "$tmp_headers" 2>/dev/null | cut -d' ' -f2 | tr -d '\r\n' || true)
    rm -f "$tmp_headers"

    # 5. Clear existing configs and services, then extract new configs
    remove_existing_install
    if ! unzip -o "$tmp_zip" -d /opt/centrunk/configs/; then
        print_error "Failed to extract configuration files"
        rm -f "$tmp_zip"
        exit 1
    fi

    # 6. Cleanup
    rm -f "$tmp_zip"

    # 7. Cache the assigned device name for re-runs that skip this flow
    save_netbird_hostname

    DEVICE_SETUP_COMPLETED=true
    STATUS_DEVICE_SETUP="provisioned"
    print_status "Configuration files installed to /opt/centrunk/configs/"
}

# myCTRS only hands out the device name during the authorization flow, so cache it.
# Without this, a re-run that skips device setup (--skip-device-setup, or declining
# the overwrite prompt) would have no name to give NetBird.
save_netbird_hostname() {
    if [[ -z "${NETBIRD_HOSTNAME:-}" ]]; then
        return
    fi

    printf '%s\n' "$NETBIRD_HOSTNAME" > "$NETBIRD_HOSTNAME_FILE"
    chmod 644 "$NETBIRD_HOSTNAME_FILE"
}

# Recover the cached device name when this run never talked to CTRS. A name from the
# current run always wins, so a device renamed server-side picks the new one up.
load_netbird_hostname() {
    if [[ -n "${NETBIRD_HOSTNAME:-}" ]]; then
        return
    fi
    if [[ ! -f "$NETBIRD_HOSTNAME_FILE" ]]; then
        return
    fi

    NETBIRD_HOSTNAME=$(tr -d '\r\n' < "$NETBIRD_HOSTNAME_FILE")
    if [[ -n "$NETBIRD_HOSTNAME" ]]; then
        print_status "Using saved device name: ${NETBIRD_HOSTNAME}"
    fi
}

# Set the system hostname to the name myCTRS assigned this device, but only when the
# box is still on the stock Pi OS default. A hostname an operator chose deliberately
# is left alone; NetBird is told the right name either way (see connect_netbird).
set_hostname() {
    local old_hostname
    old_hostname=$(hostname)

    if [[ "$old_hostname" != "raspberrypi" ]]; then
        print_status "Hostname '${old_hostname}' is not the default - leaving it unchanged"
        STATUS_HOSTNAME="unchanged (${old_hostname})"
        return
    fi

    if [[ -z "${NETBIRD_HOSTNAME:-}" ]]; then
        print_warning "No hostname provided by CTRS, leaving hostname as '${old_hostname}'"
        STATUS_HOSTNAME="no server hostname"
        return
    fi

    local new_hostname="$NETBIRD_HOSTNAME"

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

    # Join under the name CTRS assigned, regardless of what the system hostname is.
    local nb_args=(
        --management-url https://netbird.centrunk.net
        --allow-server-ssh
        --setup-key "$NETBIRD_SETUP_KEY"
    )
    if [[ -n "${NETBIRD_HOSTNAME:-}" ]]; then
        nb_args+=(--hostname "$NETBIRD_HOSTNAME")
    else
        print_warning "No hostname provided by CTRS - NetBird will use the system hostname"
    fi

    print_status "NetBird setup key received from CTRS, joining VPN..."
    if netbird up "${nb_args[@]}"; then
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

    # Map static config files to their corresponding service units.
    # VC units are handled separately because a trunked site may ship multiple
    # voice channels (configVC.yml, configVC2.yml, configVC3.yml, ...) and each
    # one needs its own centrunk.vc[N].service generated from the VC template.
    local -A config_to_service=(
        ["configCC.yml"]="centrunk.cc.service"
        ["configDVRS.yml"]="centrunk.dvrs.service"
        ["configCONVENTIONAL.yml"]="centrunk.conv.service"
    )

    # Discover VC instances: map generated service name -> source config filename.
    local -A vc_service_to_config=()
    shopt -s nullglob
    for cfg_path in /opt/centrunk/configs/configVC*.yml; do
        local cfg_name suffix
        cfg_name=$(basename "$cfg_path")          # configVC.yml, configVC2.yml, ...
        suffix="${cfg_name#configVC}"             # ".yml", "2.yml", ...
        suffix="${suffix%.yml}"                   # "", "2", "3", ...
        # Reject anything that isn't empty or all digits (e.g. configVCfoo.yml)
        if [[ -n "$suffix" && ! "$suffix" =~ ^[0-9]+$ ]]; then
            print_warning "Ignoring unexpected config: ${cfg_name}"
            continue
        fi
        vc_service_to_config["centrunk.vc${suffix}.service"]="$cfg_name"
    done
    shopt -u nullglob

    # Determine which services to install based on configs present
    local services=()
    for config in "${!config_to_service[@]}"; do
        if [[ -f "/opt/centrunk/configs/${config}" ]]; then
            services+=("${config_to_service[$config]}")
        fi
    done
    for svc in "${!vc_service_to_config[@]}"; do
        services+=("$svc")
    done

    if [[ ${#services[@]} -eq 0 ]]; then
        print_warning "No config files found in /opt/centrunk/configs/ — skipping service installation"
        STATUS_SERVICES="no configs found"
        return
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d)

    # Download the VC template once if any VC instances need to be installed.
    local vc_template=""
    if [[ ${#vc_service_to_config[@]} -gt 0 ]]; then
        vc_template="${tmp_dir}/centrunk.vc.service"
        local vc_url="${INSTALLER_REPO_RAW}/systemd/centrunk.vc.service"
        print_status "Downloading centrunk.vc.service template..."
        if ! curl -fsSL -o "$vc_template" "$vc_url"; then
            print_error "Failed to download centrunk.vc.service template from ${vc_url}"
            rm -rf "$tmp_dir"
            exit 1
        fi
    fi

    for svc in "${services[@]}"; do
        if [[ -n "${vc_service_to_config[$svc]:-}" ]]; then
            # VC instance — generate from template by patching ExecStart's config path
            local cfg="${vc_service_to_config[$svc]}"
            print_status "Generating ${svc} for ${cfg}..."
            sed -E "s|(-c[[:space:]]+/opt/centrunk/configs/)configVC\.yml|\1${cfg}|" \
                "$vc_template" > "/etc/systemd/system/${svc}"
        else
            # Static unit — download from repo as before
            local url="${INSTALLER_REPO_RAW}/systemd/${svc}"
            print_status "Downloading ${svc}..."
            if ! curl -fsSL -o "${tmp_dir}/${svc}" "$url"; then
                print_error "Failed to download ${svc} from ${url}"
                rm -rf "$tmp_dir"
                exit 1
            fi
            cp "${tmp_dir}/${svc}" /etc/systemd/system/
        fi
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
    print_step "Memory check"         "$STATUS_MEMORY"
    print_step "Prerequisites"        "$STATUS_PREREQUISITES"
    print_step "Package upgrade"      "$STATUS_UPGRADE"
    print_step "Osquery removal"      "$STATUS_OSQUERY_REMOVE"
    print_step "Netbird install"      "$STATUS_NETBIRD_INSTALL"
    print_step "Directory structure"  "$STATUS_DIRECTORIES"
    print_step "Firmware source"      "$STATUS_FIRMWARE_CLONE"
    print_step "Firmware build"       "$STATUS_FIRMWARE_BUILD"
    print_step "Console params"       "$STATUS_CONSOLE_PARAMS"
    print_step "Bluetooth/UART"       "$STATUS_BLUETOOTH"
    print_step "DVMHost binary"       "$STATUS_DVMHOST"
    print_step "Device config"        "$STATUS_DEVICE_SETUP"
    print_step "Hostname"             "$STATUS_HOSTNAME"
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
            local retry_hostname_arg=""
            if [[ -n "${NETBIRD_HOSTNAME:-}" ]]; then
                retry_hostname_arg=" --hostname ${NETBIRD_HOSTNAME}"
            fi
            echo "      sudo netbird up --management-url https://netbird.centrunk.net --allow-server-ssh --setup-key ${NETBIRD_SETUP_KEY}${retry_hostname_arg}"
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
    echo "Version: $INSTALLER_VERSION"
    echo "======================================"
    echo ""

    check_root
    load_claim_token
    check_platform
    check_memory
    setup_ctrs_user
    stop_running_services
    install_prerequisites
    upgrade_system
    remove_osquery
    install_netbird
    create_directories
    clone_firmware
    build_firmware
    remove_console_params
    disable_bluetooth
    install_dvmhost
    setup_device_config
    load_netbird_hostname
    set_hostname
    connect_netbird
    install_services
    fix_permissions
    print_summary
}

# Run main function
main "$@"
