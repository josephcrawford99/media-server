# Headless Media Server (macOS Monterey, Intel)

Plex + Transmission + Prowlarr via Docker (Colima) on an old MacBook Pro.

## Prerequisites

1. **Xcode Command Line Tools**: `xcode-select --install`
2. **MacPorts**: Download the Monterey `.pkg` from https://www.macports.org/install.php

## Quick Start

```bash
git clone <this-repo> media-server-setup
cd media-server-setup
chmod +x setup.sh
./setup.sh
```

The script installs everything, prompts for your Plex claim token, configures power settings, and starts all services.

## Services

| Service      | URL                         | Purpose             |
|-------------|-----------------------------|---------------------|
| Plex        | http://SERVER:32400/web     | Media streaming     |
| Transmission| http://SERVER:9091          | BitTorrent client   |
| Prowlarr    | http://SERVER:9696          | Indexer manager     |

## Directory Layout

```
~/media-server/
├── config/{plex,transmission,prowlarr}/
├── media/{movies,tv,music,downloads/watch}/
└── docker-compose.yml
```

Drop `.torrent` files in `media/downloads/watch/` for auto-download.

## After Setup

- **Enable auto-login**: System Preferences → Users & Groups → Login Options
- **Keep plugged in**: Required for lid-closed (clamshell) mode
- **Wake on LAN**: MAC address is printed by setup.sh — use any WOL app

## Management

```bash
cd ~/media-server
docker-compose logs -f                          # view logs
docker-compose restart                          # restart all
docker-compose pull && docker-compose up -d     # update images
colima status                                   # VM status
pmset -g                                        # power settings
```

## Power Settings

The setup script configures the Mac to stay awake with display off (`sleep 0` + `displaysleep 2`). Idle draw is ~5-15W. Wake on LAN is enabled as a fallback. Spotlight indexing is disabled on media directories.
