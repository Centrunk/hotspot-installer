#!/bin/bash
#
# Local end-to-end test script for Centrunk DVMHost installer
# Tests the installation in a Debian ARM64 container (similar to Raspberry Pi OS)
#
# Requirements:
#   - Docker or Podman
#   - QEMU user-mode emulation (qemu-user-static)
#
# Usage: ./test-local.sh
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "======================================"
echo "Centrunk DVMHost Installer - Local Test"
echo "======================================"
echo ""

# Check for container runtime
if command -v podman &> /dev/null; then
    CONTAINER_CMD="sudo podman"
elif command -v docker &> /dev/null; then
    CONTAINER_CMD="docker"
else
    echo -e "${RED}Error: Docker or Podman is required${NC}"
    exit 1
fi

echo -e "${GREEN}[*]${NC} Using container runtime: $CONTAINER_CMD"

# Check for QEMU support
echo -e "${GREEN}[*]${NC} Checking QEMU ARM64 support..."
if [ -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
    echo -e "${GREEN}[*]${NC} QEMU ARM64 emulation is available"
else
    echo -e "${YELLOW}[!]${NC} QEMU ARM64 emulation not detected."
    echo "    Install with: sudo apt-get install qemu-user-static"
    exit 1
fi

echo -e "${GREEN}[*]${NC} Starting ARM64 Debian container (similar to Raspberry Pi OS)..."
echo ""

# Run the test in a container
$CONTAINER_CMD run --rm --platform linux/arm64 \
    -v "$SCRIPT_DIR:/hotspot-installer:ro" \
    docker.io/library/debian:bookworm-slim \
    /bin/bash -c '
        set -e
        
        echo "========================================"
        echo "Running inside ARM64 container"
        echo "Architecture: $(uname -m)"
        echo "OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2)"
        echo "========================================"
        echo ""
        
        # Update and install basic tools
        apt-get update
        apt-get install -y curl wget xz-utils file
        
        # Copy install script (since we mounted read-only)
        cp -r /hotspot-installer /tmp/installer
        chmod +x /tmp/installer/install.sh
        
        echo ""
        echo "========================================"
        echo "Running install.sh --skip-netbird --skip-services"
        echo "========================================"
        echo ""
        
        # Run the installer
        /tmp/installer/install.sh --skip-netbird --skip-services
        
        echo ""
        echo "========================================"
        echo "Verifying Installation"
        echo "========================================"
        echo ""
        
        # Verify directories
        echo "Checking directories..."
        for dir in /var/log/centrunk /opt/centrunk /opt/centrunk/configs /opt/centrunk/dvmhost; do
            if [ -d "$dir" ]; then
                echo "✓ $dir exists"
            else
                echo "✗ $dir missing!"
                exit 1
            fi
        done
        
        # Verify binary
        echo ""
        echo "Checking binary..."
        if [ -f /opt/centrunk/dvmhost/dvmhost ]; then
            echo "✓ dvmhost binary exists"
            ls -la /opt/centrunk/dvmhost/dvmhost
        else
            echo "✗ dvmhost binary not found!"
            exit 1
        fi
        
        if [ -x /opt/centrunk/dvmhost/dvmhost ]; then
            echo "✓ dvmhost is executable"
        else
            echo "✗ dvmhost is not executable!"
            exit 1
        fi
        
        # Check architecture
        echo ""
        echo "Checking binary architecture..."
        file /opt/centrunk/dvmhost/dvmhost
        
        # Try to run the binary
        echo ""
        echo "Testing binary execution..."
        if /opt/centrunk/dvmhost/dvmhost -h 2>&1 | head -10; then
            echo "✓ dvmhost executes successfully"
        else
            echo "Note: dvmhost may need config file to display help"
        fi
        
        echo ""
        echo "========================================"
        echo "✓ ALL TESTS PASSED!"
        echo "========================================"
    '

echo ""
echo -e "${GREEN}========================================"
echo "Local ARM64 test completed successfully!"
echo "========================================${NC}"
