# Centrunk DVMHost Installation Script

Automated installation script for compiling and installing [DVMHost](https://github.com/DVMProject/dvmhost) on Raspberry Pi OS (64-bit).

[![Test Installation on Raspberry Pi OS](https://github.com/Centrunk/hotspot-installer/actions/workflows/test-install.yml/badge.svg)](https://github.com/Centrunk/hotspot-installer/actions/workflows/test-install.yml)

## Features

- Automated installation of all prerequisites
- Netbird VPN installation
- DVMHost compilation from source
- Systemd service installation for Control Channel (CC) and Voice Channel (VC)
- Support for Raspberry Pi OS 64-bit

## Quick Start

```bash
# Clone this repository
git clone https://github.com/Centrunk/hotspot-installer.git
cd hotspot-installer

# Make the script executable
chmod +x install.sh

# Run the installation
sudo ./install.sh
```

## Installation Options

```bash
# Full installation
sudo ./install.sh

# Skip Netbird installation
sudo ./install.sh --skip-netbird

# Skip systemd service installation
sudo ./install.sh --skip-services

# Show help
./install.sh --help
```

## What Gets Installed

### Prerequisites
- git
- nano
- stm32flash
- gcc-arm-none-eabi
- cmake
- libasio-dev
- libncurses-dev
- libssl-dev
- build-essential

### Software
- **Netbird** - VPN client for secure networking
- **DVMHost** - Digital Voice Modem host software

### Directory Structure
```
/opt/centrunk/
├── dvmhost/          # DVMHost source and binary
│   └── dvmhost       # Compiled binary
└── configs/          # Configuration files
    ├── configCC.yml  # Control Channel config (you create this)
    └── configVC.yml  # Voice Channel config (you create this)

/var/log/centrunk/    # Log directory
```

### Systemd Services
- `centrunk.cc.service` - Control Channel service
- `centrunk.vc.service` - Voice Channel service

## Post-Installation

### 1. Create Configuration Files

You need to create your configuration files before starting the services:

```bash
# Create/edit Control Channel config
sudo nano /opt/centrunk/configs/configCC.yml

# Create/edit Voice Channel config
sudo nano /opt/centrunk/configs/configVC.yml
```

### 2. Start Services

```bash
# Start Control Channel
sudo systemctl start centrunk.cc.service

# Start Voice Channel
sudo systemctl start centrunk.vc.service

# Check status
sudo systemctl status centrunk.cc.service
sudo systemctl status centrunk.vc.service
```

### 3. Configure Netbird (if installed)

```bash
sudo netbird up
```

## Service Management

```bash
# Start services
sudo systemctl start centrunk.cc.service
sudo systemctl start centrunk.vc.service

# Stop services
sudo systemctl stop centrunk.cc.service
sudo systemctl stop centrunk.vc.service

# Restart services
sudo systemctl restart centrunk.cc.service
sudo systemctl restart centrunk.vc.service

# View logs
sudo journalctl -u centrunk.cc.service -f
sudo journalctl -u centrunk.vc.service -f

# Disable services
sudo systemctl disable centrunk.cc.service
sudo systemctl disable centrunk.vc.service
```

## Automated Testing

This repository includes GitHub Actions workflows that automatically test the installation script on:

- **Raspberry Pi OS 64-bit** (ARM64) - Using QEMU emulation
- **Debian ARM64** - Fallback compatibility test
- **Shell script syntax** - Using shellcheck
- **Script logic** - Basic functionality tests

Tests run on every push and pull request.

## Requirements

- Raspberry Pi OS 64-bit (Bookworm or newer recommended)
- Raspberry Pi 3, 4, or 5 (64-bit capable)
- Internet connection
- Root/sudo access

## Troubleshooting

### Build Fails

If the DVMHost build fails, check:
1. Sufficient disk space (at least 2GB free)
2. Sufficient RAM (1GB+ recommended)
3. All prerequisites are installed

```bash
# Check disk space
df -h

# Check memory
free -h

# Retry build manually
cd /opt/centrunk/dvmhost/build
sudo make clean
sudo make -j$(nproc) dvmhost
```

### Service Won't Start

1. Verify configuration files exist:
```bash
ls -la /opt/centrunk/configs/
```

2. Check service logs:
```bash
sudo journalctl -u centrunk.cc.service -n 50
```

3. Verify binary exists:
```bash
ls -la /opt/centrunk/dvmhost/dvmhost
```

## License

This installation script is provided as-is. DVMHost is a separate project with its own license - see the [DVMHost repository](https://github.com/DVMProject/dvmhost) for details.
