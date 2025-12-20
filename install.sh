#!/bin/bash
#
# Centrunk DVMHost Installation Script
# Automates compilation and installation on Raspberry Pi OS (64-bit)
#
# Usage: sudo ./install.sh [options]
#   Options:
#     --skip-netbird    Skip Netbird installation
#     --skip-services   Skip systemd service installation
#     --help            Show this help message
#

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default options
SKIP_NETBIRD=false
SKIP_SERVICES=false

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
        --help)
            echo "Centrunk DVMHost Installation Script"
            echo ""
            echo "Usage: sudo ./install.sh [options]"
            echo ""
            echo "Options:"
            echo "  --skip-netbird    Skip Netbird installation"
            echo "  --skip-services   Skip systemd service installation"
            echo "  --help            Show this help message"
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

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Check if running on Raspberry Pi OS
check_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        if [[ "$ID" != "raspbian" && "$ID" != "debian" ]]; then
            print_warning "This script is designed for Raspberry Pi OS (Debian-based)"
            print_warning "Detected: $PRETTY_NAME"
            read -p "Continue anyway? (y/N) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                exit 1
            fi
        fi
    fi
}

# Install prerequisites
install_prerequisites() {
    print_status "Updating package lists..."
    apt-get update

    print_status "Installing prerequisites..."
    apt-get install -y \
        git \
        nano \
        stm32flash \
        gcc-arm-none-eabi \
        cmake \
        libasio-dev \
        libncurses-dev \
        libssl-dev \
        build-essential

    print_status "Prerequisites installed successfully"
}

# Install Netbird
install_netbird() {
    if [[ "$SKIP_NETBIRD" == "true" ]]; then
        print_warning "Skipping Netbird installation (--skip-netbird flag)"
        return
    fi

    print_status "Installing Netbird..."
    curl -fsSL https://pkgs.netbird.io/install.sh | sh

    print_status "Netbird installed successfully"
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
}

# Clone and build dvmhost
build_dvmhost() {
    print_status "Cloning DVMHost repository..."

    cd /opt/centrunk

    # Remove existing dvmhost directory if it exists
    if [[ -d /opt/centrunk/dvmhost ]]; then
        print_warning "Removing existing dvmhost directory..."
        rm -rf /opt/centrunk/dvmhost
    fi

    git clone --recurse-submodules https://github.com/DVMProject/dvmhost.git

    print_status "Building DVMHost..."
    cd /opt/centrunk/dvmhost

    # Create build directory for out-of-source build
    mkdir -p build
    cd build

    cmake ..
    make -j$(nproc) dvmhost

    # Copy the binary to the expected location
    if [[ -f dvmhost ]]; then
        cp dvmhost /opt/centrunk/dvmhost/
        print_status "DVMHost built successfully"
    else
        print_error "Build failed - dvmhost binary not found"
        exit 1
    fi
}

# Install systemd services
install_services() {
    if [[ "$SKIP_SERVICES" == "true" ]]; then
        print_warning "Skipping systemd service installation (--skip-services flag)"
        return
    fi

    print_status "Installing systemd services..."

    # Get the directory where this script is located
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # Install CC service
    if [[ -f "$SCRIPT_DIR/systemd/centrunk.cc.service" ]]; then
        cp "$SCRIPT_DIR/systemd/centrunk.cc.service" /etc/systemd/system/
        print_status "Installed centrunk.cc.service"
    else
        print_warning "centrunk.cc.service not found in $SCRIPT_DIR/systemd/"
    fi

    # Install VC service
    if [[ -f "$SCRIPT_DIR/systemd/centrunk.vc.service" ]]; then
        cp "$SCRIPT_DIR/systemd/centrunk.vc.service" /etc/systemd/system/
        print_status "Installed centrunk.vc.service"
    else
        print_warning "centrunk.vc.service not found in $SCRIPT_DIR/systemd/"
    fi

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
        echo "  4. Configure Netbird:"
        echo "     sudo netbird up"
        echo ""
    fi
}

# Main installation flow
main() {
    echo "======================================"
    echo "Centrunk DVMHost Installation Script"
    echo "======================================"
    echo ""

    check_root
    check_os
    install_prerequisites
    install_netbird
    create_directories
    build_dvmhost
    install_services
    print_summary
}

# Run main function
main "$@"
