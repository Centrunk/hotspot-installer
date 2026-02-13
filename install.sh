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

# Default options
SKIP_NETBIRD=false
SKIP_SERVICES=false
SKIP_FIRMWARE_BUILD=false
SKIP_PLATFORM_CHECK=false
NON_INTERACTIVE=false

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
        read -p "Continue anyway? (y/N) " -n 1 -r
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

    # Check if Netbird is already running
    if systemctl is-active --quiet netbird 2>/dev/null || pgrep -x netbird >/dev/null 2>&1; then
        print_status "Netbird is already running - skipping installation"
        NETBIRD_ALREADY_RUNNING=true
        return
    fi

    if [ ! $NETBIRD_ALREADY_RUNNING ]; then
      print_status "Installing Netbird..."
      curl -fsSL https://pkgs.netbird.io/install.sh | sh
    fi


    print_status "Netbird installed successfully"
    NETBIRD_ALREADY_RUNNING=false
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
        git -C "$dest" pull --recurse-submodules || print_warning "git pull failed - continuing with existing checkout"
        return
    fi

    print_status "Cloning dvmfirmware-hs..."
    if ! git clone --recurse-submodules https://github.com/DVMProject/dvmfirmware-hs.git "$dest"; then
        print_error "Failed to clone dvmfirmware-hs"
        exit 1
    fi
    print_status "dvmfirmware-hs cloned to $dest"
}

# Build firmware for MMDVM_HS_Hat (dual)
build_firmware() {
    if [[ "$SKIP_FIRMWARE_BUILD" == "true" ]]; then
        print_warning "Skipping firmware build (--skip-firmware-build flag)"
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
    for cmdline_file in /boot/cmdline.txt /boot/firmware/cmdline.txt; do
        if [[ -f "$cmdline_file" ]] && grep -q "console=" "$cmdline_file"; then
            cp "$cmdline_file" "${cmdline_file}.backup"
            sed -i 's/console=[^ ]*//g; s/  */ /g; s/^ //; s/ $//' "$cmdline_file"
            modified=true
        fi
    done
    if [[ "$modified" == "true" ]]; then
        print_warning "Boot cmdline modified - reboot required"
    fi
}

# Disable Bluetooth to free up ttyAMA0
disable_bluetooth() {
    local config_file=""
    [[ -f /boot/firmware/config.txt ]] && config_file="/boot/firmware/config.txt"
    [[ -f /boot/config.txt ]] && config_file="/boot/config.txt"
    
    if [[ -z "$config_file" ]]; then
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
    echo "  1. Create your configuration files:"
    echo "     - /opt/centrunk/configs/configCC.yml"
    echo "     - /opt/centrunk/configs/configVC.yml"
    echo ""
    echo "  2. Start the services:"
    echo "     sudo systemctl start centrunk.cc.service"
    echo "     sudo systemctl start centrunk.vc.service"
    echo ""
    echo "  3. Check service status:"
    echo "     sudo systemctl status centrunk.cc.service"
    echo "     sudo systemctl status centrunk.vc.service"
    echo ""
    if [[ "$SKIP_NETBIRD" != "true" ]]; then
        if [[ "${NETBIRD_ALREADY_RUNNING:-false}" == "true" ]]; then
            echo "  4. Netbird Status:"
            echo "     Netbird was already running on this system"
            echo "     No configuration needed - using existing setup"
        else
            echo "  4. Configure Netbird (using the correct hostname):"
            echo "     sudo netbird up --management-url https://netbird.centrunk.net --allow-server-ssh --setup-key C284219E-4A20-4DF3-A414-B2E507131BC4 --hostname hs-4DIGITRID-RFSS-SITE"
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
    install_services
    print_summary
}

# Run main function
main "$@"
