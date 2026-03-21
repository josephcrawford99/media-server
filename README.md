# Headless Media Server (macOS Monterey, Intel)

Plex + Sonarr + Radarr + Prowlarr + Transmission via Docker (Colima) on an old MacBook Pro.

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

The script installs everything, configures all app connections automatically, and starts all services.

## Services

| Service      | URL                         | Purpose                    |
|-------------|-----------------------------|----------------------------|
| Plex        | http://SERVER:32400/web     | Media streaming            |
| Sonarr      | http://SERVER:8989          | TV show management         |
| Radarr      | http://SERVER:7878          | Movie management           |
| Prowlarr    | http://SERVER:9696          | Indexer/tracker manager    |
| Transmission| http://SERVER:9091          | BitTorrent download client |
| FlareSolverr| http://SERVER:8191          | Cloudflare bypass proxy    |

## How It Works

```
Prowlarr (manages trackers/indexers)
    ↓ syncs indexers to
Sonarr (TV) / Radarr (Movies)
    ↓ sends .torrent to
Transmission (downloads to data/torrents/)
    ↓ on completion
Sonarr/Radarr hardlink to data/media/ (renamed, organized)
    ↓
Plex detects and serves
```

## Directory Layout

TRaSH Guides pattern — single `/data` root enables hardlinks (instant, zero extra disk space).

```
~/media-server/
├── config/{plex,transmission,prowlarr,sonarr,radarr}/
└── data/
    ├── torrents/          ← Transmission downloads here
    │   ├── movies/        ← Radarr category
    │   ├── tv/            ← Sonarr category
    │   ├── music/
    │   └── watch/         ← drop .torrent files here
    └── media/             ← organized media, Plex reads from here
        ├── movies/        ← Radarr root folder
        ├── tv/            ← Sonarr root folder
        └── music/
```

## After Setup

1. **Add indexers**: Prowlarr → Indexers → Add (pick your trackers). They auto-sync to Sonarr/Radarr.
2. **Add movies**: Radarr → Movies → Add New → search → add
3. **Add TV shows**: Sonarr → Series → Add New → search → add (monitors for new episodes)
4. **Enable auto-login**: System Preferences → Users & Groups → Login Options
5. **Keep plugged in**: Required for lid-closed (clamshell) mode

## Management

```bash
cd ~/media-server
docker compose logs -f                          # view logs
docker compose restart                          # restart all
docker compose pull && docker compose up -d     # update images
colima status                                   # VM status
pmset -g                                        # power settings
```
