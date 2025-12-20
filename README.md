# Centrunk DVMHost Installation Script

Automated installation script for installing [DVMHost](https://github.com/DVMProject/dvmhost) on Raspberry Pi OS (64-bit).

[![Test Installation on Raspberry Pi OS](https://github.com/Centrunk/hotspot-installer/actions/workflows/test-install.yml/badge.svg)](https://github.com/Centrunk/hotspot-installer/actions/workflows/test-install.yml)

## Features

- Automated installation of all prerequisites
- Netbird VPN installation
- Pre-built DVMHost binary download from [Centrunk/dvmbins](https://github.com/Centrunk/dvmbins)
- Automatic architecture detection (arm64, armhf, amd64)
- Platform verification (Raspberry Pi OS Bookworm/Trixie 64-bit)
- Systemd service installation for Control Channel (CC) and Voice Channel (VC)
- One-liner installation support

## One-Liner Installation

Run this command on your Raspberry Pi:

```bash
curl -fsSL https://raw.githubusercontent.com/Centrunk/hotspot-installer/main/install.sh | sudo bash
```

Or with wget:

```bash
wget -qO- https://raw.githubusercontent.com/Centrunk/hotspot-installer/main/install.sh | sudo bash
```

## Manual Installation

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

# Non-interactive mode (no prompts)
sudo ./install.sh -y

# Skip Netbird installation
sudo ./install.sh --skip-netbird

# Skip systemd service installation
sudo ./install.sh --skip-services

# Show help
./install.sh --help
```

## What Gets Installed

### Prerequisites
- curl
- wget
- xz-utils
- stm32flash

### Software
- **Netbird** - VPN client for secure networking
- **DVMHost** - Digital Voice Modem host software (pre-built binary)

### Directory Structure
```
/opt/centrunk/
├── dvmhost/          # DVMHost binary
│   └── dvmhost       # Pre-built binary
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
- **Shell script syntax** - Using shellcheck
- **Script logic** - Basic functionality tests

Tests run on every push and pull request.

## Requirements

- Raspberry Pi OS 64-bit (Bookworm or newer recommended)
- Raspberry Pi 3, 4, or 5 (64-bit capable)
- Internet connection
- Root/sudo access

## Troubleshooting

### Download Fails

If the DVMHost binary download fails, check:
1. Internet connectivity
2. GitHub is accessible
3. Correct architecture is detected

```bash
# Check your architecture
uname -m

# Manual download (for arm64)
wget https://github.com/Centrunk/dvmbins/raw/master/dvmhost-arm64.tar.xz
tar -xJf dvmhost-arm64.tar.xz
sudo cp dvmhost /opt/centrunk/dvmhost/
sudo chmod +x /opt/centrunk/dvmhost/dvmhost
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
