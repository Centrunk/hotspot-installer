# Centrunk DVMHost Installation Script

Automated installation script for installing [DVMHost](https://github.com/DVMProject/dvmhost) on Raspberry Pi OS or Debian Trixie (64-bit).

[![Test Installation on Raspberry Pi OS](https://github.com/Centrunk/hotspot-installer/actions/workflows/test-install.yml/badge.svg)](https://github.com/Centrunk/hotspot-installer/actions/workflows/test-install.yml)

## Features

- Automated installation of all prerequisites
- Netbird VPN installation
- Pre-built DVMHost binary download from [Centrunk/dvmbins](https://github.com/Centrunk/dvmbins)
- Automatic architecture detection (arm64, armhf, amd64)
- Platform verification (Raspberry Pi OS Bookworm/Trixie or Debian Trixie, 64-bit aarch64/x86_64; minimum 4GB RAM)
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

# Pair headlessly with a myCTRS claim token (unattended / first boot)
sudo ./install.sh -y --claim-token-file /etc/centrunk/claim-token

# Show help
./install.sh --help
```

### Unattended pairing with a claim token

`--claim-token-file <path>` (or the `CTRS_CLAIM_TOKEN_FILE` environment variable)
lets a headless device pair without anyone reading its console. The file holds a
claim token minted in myCTRS; surrounding whitespace is ignored, and the installer
stops immediately if the file is missing, empty, or not a valid token.

- The device registers as **claimed** and appears in the owner's queue. Approve it
  on the **Hotspot Claims** page (`https://my.centrunk.net/device/claims/`, or
  `<ctrs-url>/device/claims/`). The token only routes the device to
  you; it never authorizes anything by itself.
- The token is never printed and never placed on a command line (it is sent to
  curl on stdin), so it does not show up in `ps`.
- With a claim token, the installer waits indefinitely: an expired code is
  replaced by a fresh registration, and network errors, rate limits (HTTP
  403/429) and server errors are retried with exponential backoff capped at 60s.
  A configuration that someone else already downloaded is still fatal, and so is
  a claim token the server rejects (expired, revoked or already used) — mint a
  new one and re-flash the card.
- With a claim token, existing configs in `/opt/centrunk/configs/` are kept and
  pairing is skipped. Run without a token to replace them.
- Without a claim token nothing changes, with or without `-y`: the installer
  shows the device code, exits on any pairing failure or expired code, and asks
  before overwriting existing configs.

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

## Development Setup

After cloning, enable the version-stamp hook so each commit auto-updates the
`INSTALLER_VERSION` line printed at the top of every install run:

```bash
git config core.hooksPath .githooks
```

The hook lives at `.githooks/pre-commit`. It is inert until activated per-clone
with the command above. Without it, commits land with `INSTALLER_VERSION="dev"`
unchanged — a deliberate graceful-degradation path, not a failure.

## Automated Testing

This repository includes GitHub Actions workflows that automatically test the installation script on:

- **Raspberry Pi OS 64-bit** (ARM64) - Using QEMU emulation
- **Shell script syntax** - Using shellcheck
- **Script logic** - Basic functionality tests

Tests run on every push and pull request.

## Requirements

- One of:
  - Raspberry Pi OS 64-bit (Bookworm or Trixie) on a Raspberry Pi 3, 4, or 5
  - Debian Trixie 64-bit (aarch64 or x86_64)
- Minimum 4GB RAM
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
