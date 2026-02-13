# Centrunk DVMHost Installer

## Project Overview

Automated installation script for [DVMHost](https://github.com/DVMProject/dvmhost) on Raspberry Pi OS (64-bit). The installer sets up a P25 trunked radio system hotspot including VPN connectivity, pre-built binaries, firmware compilation, UART/Bluetooth configuration, and systemd services.

**Repository:** `Centrunk/hotspot-installer`

## Project Structure

```
install.sh               # Main installer script (bash, runs as root)
test-local.sh            # Local end-to-end test using Docker/Podman + QEMU ARM64
systemd/
  centrunk.cc.service    # Control Channel systemd unit
  centrunk.vc.service    # Voice Channel systemd unit
.github/workflows/
  test-install.yml       # CI: ARM64 Pi OS test, shellcheck, x86 logic test, Discord notifications
README.md                # User-facing documentation
TODO.md                  # Project backlog
```

## Installation Script Requirements

### Target Platform
- Raspberry Pi OS 64-bit (Bookworm or Trixie) on Raspberry Pi 3/4/5
- Architecture: `aarch64` required; script also maps `armhf` and `amd64` for binary downloads
- Platform check validates: 64-bit ARM, Raspberry Pi OS (via `/etc/rpi-issue`, `PRETTY_NAME`, or `ID=raspbian`), Bookworm/Trixie codename, 64-bit OS

### Installation Flow (in order)
1. `check_root` - Must run as root
2. `check_platform` - Verify Pi OS Bookworm/Trixie 64-bit (skippable)
3. `install_prerequisites` - apt packages: git, curl, wget, xz-utils, stm32flash, make, gcc-arm-none-eabi, binutils-arm-none-eabi, libnewlib-arm-none-eabi
4. `install_netbird` - VPN client via `pkgs.netbird.io/install.sh` (skips if already running)
5. `create_directories` - `/opt/centrunk/{dvmhost,configs}`, `/var/log/centrunk/`
6. `clone_firmware` - Clone `DVMProject/dvmfirmware-hs` to `/opt/centrunk/dvmfirmware-hs`
7. `build_firmware` - Build `mmdvm-hs-hat-dual` target via `Makefile.STM32FX`
8. `remove_console_params` - Strip `console=` params from boot cmdline
9. `disable_bluetooth` - Pi model-specific dtoverlay config, disable/mask BT and serial services
10. `install_dvmhost` - Download pre-built binary from `Centrunk/dvmbins` (arch-specific `.tar.xz`)
11. `install_services` - Download systemd units from this repo's raw GitHub URL, enable (don't start)
12. `print_summary` - Show next steps including Netbird setup key and reboot reminder

### CLI Options
- `--skip-netbird` - Skip VPN installation
- `--skip-services` - Skip systemd service setup
- `--skip-firmware-build` - Skip firmware compilation
- `--skip-platform-check` - Bypass platform verification (for testing)
- `-y` / `--yes` - Non-interactive mode (auto-detected when piped)
- `--help` - Show usage

### One-liner Support
Script detects piped input (`[[ ! -t 0 ]]`) and auto-enables non-interactive mode. Service files are downloaded from the raw GitHub URL rather than relying on local files.

## Directory Layout on Target

```
/opt/centrunk/
├── dvmhost/dvmhost          # Pre-built binary
├── dvmfirmware-hs/          # Firmware source (cloned from DVMProject)
└── configs/
    ├── configCC.yml          # Control Channel config (user-created)
    └── configVC.yml          # Voice Channel config (user-created)
/var/log/centrunk/            # Log directory
```

## Systemd Services
- `centrunk.cc.service` - Control Channel: runs `/opt/centrunk/dvmhost/dvmhost -c /opt/centrunk/configs/configCC.yml`
- `centrunk.vc.service` - Voice Channel: runs `/opt/centrunk/dvmhost/dvmhost -c /opt/centrunk/configs/configVC.yml`
- Both: `Type=forking`, `Restart=on-abnormal`, `User=root`

## Coding Conventions

### Bash Style
- `set -e` at top of all scripts
- Color constants: `RED`, `GREEN`, `YELLOW`, `NC`
- Status functions: `print_status()` (green), `print_warning()` (yellow), `print_error()` (red)
- Each logical step is its own function called from `main()`
- Use `[[ ]]` for conditionals, not `[ ]`
- Quote all variable expansions
- Use `local` for function-scoped variables
- Idempotent: check if directories/services exist before creating
- Cleanup temp files with `rm -rf "$temp_dir"` after use

### Error Handling
- `set -e` for fail-fast
- Critical failures call `print_error` then `exit 1`
- Non-critical issues use `print_warning` and continue
- Platform check allows interactive override in non-pipe mode

## CI/CD Pipeline

### Jobs (`.github/workflows/test-install.yml`)
1. **test-install-arm64** - Real Raspberry Pi OS image via `pguyot/arm-runner-action@v2`, runs full install with `--skip-netbird --skip-services`
2. **test-syntax** - `shellcheck` on `install.sh`, validates systemd unit structure (`[Unit]`, `[Service]`, `[Install]` sections)
3. **test-install-x86** - `bash -n` syntax check, `--help` flag test
4. **notify-discord** - Posts results to Discord via separate webhooks for success (`DISCORD_WEBHOOK_SUCCESS`) and failure (`DISCORD_WEBHOOK_FAILURE`)

### Triggers
- Push to `main`/`master`
- Pull requests to `main`/`master`
- Manual `workflow_dispatch`

## Testing

### Local Testing (`test-local.sh`)
- Uses Docker/Podman with QEMU ARM64 emulation
- Runs `debian:bookworm-slim` container with `--skip-netbird --skip-services --skip-platform-check`
- Verifies: directory structure, binary existence, binary is executable, binary architecture

### Verification Checks
After installation, verify:
- Directories exist: `/var/log/centrunk`, `/opt/centrunk`, `/opt/centrunk/configs`, `/opt/centrunk/dvmhost`
- Binary exists at `/opt/centrunk/dvmhost/dvmhost` and is executable
- Binary is correct architecture (`file` command)

## Key URLs
- Binary downloads: `https://github.com/Centrunk/dvmbins/raw/master/dvmhost-{arch}.tar.xz`
- Installer repo raw: `https://raw.githubusercontent.com/Centrunk/hotspot-installer/main/`
- Firmware source: `https://github.com/DVMProject/dvmfirmware-hs`
- Netbird management: `https://netbird.centrunk.net`
