# MacBook Joe

A headless media server for an older Intel MacBook running macOS Monterey. One script turns a retired laptop into an always-on, lid-closed Plex + *arr stack — fully automated from install to health check.

## What It Does

```
Prowlarr (manages trackers/indexers)
    ↓ syncs indexers to
Sonarr (TV) / Radarr (Movies)
    ↓ sends .torrent to
Transmission (downloads to data/torrents/)
    ↓ on completion, hardlinks to
data/media/ (renamed, organized)
    ↓
Plex detects and streams to your devices
```

**Optional**: Route all torrent traffic through a Mullvad VPN via Gluetun + WireGuard.

## Stack

| Service       | Port  | Role                            |
|---------------|-------|---------------------------------|
| Plex          | 32400 | Media streaming                 |
| Sonarr        | 8989  | TV show management              |
| Radarr        | 7878  | Movie management                |
| Prowlarr      | 9696  | Indexer/tracker manager         |
| Transmission  | 9091  | BitTorrent client               |
| FlareSolverr  | 8191  | Cloudflare bypass for indexers  |
| Gluetun       | —     | VPN tunnel (optional, Mullvad)  |

## Prerequisites

1. **Xcode CLI Tools** — `xcode-select --install`
2. **MacPorts** — [download the Monterey `.pkg`](https://www.macports.org/install.php)

## Quick Start

```bash
git clone https://github.com/josephcrawford99/media-server.git ~/media-server
cd ~/media-server
chmod +x setup.sh
./setup.sh              # deploy to ~/media-server (default)
./setup.sh /path/to/dir # or specify a different runtime directory
```

The script will:
- Install Colima, Docker, and docker-compose via MacPorts
- Prompt for CPU, RAM, and disk allocation for the Colima VM
- Create the directory structure (TRaSH Guides hardlink-friendly layout)
- Write a `.env` with your PUID/PGID/TZ
- Optionally set up Mullvad VPN
- Pull and start all containers
- Auto-configure all service connections via API (Prowlarr ↔ Sonarr/Radarr, Transmission, Plex notifications)
- Configure power management (no sleep, Wake-on-LAN, lid-closed mode)
- Install a LaunchAgent so Colima starts on boot
- Run a health check to verify everything is connected

Re-running `setup.sh` is safe — it restarts Colima with new resource settings, skips already-configured services, and re-verifies health.

## Directory Layout

[TRaSH Guides](https://trash-guides.info/) pattern — single `/data` root enables hardlinks (instant moves, zero extra disk).

```
~/media-server/
├── config/
│   ├── plex/
│   ├── sonarr/
│   ├── radarr/
│   ├── prowlarr/
│   └── transmission/
├── data/
│   ├── torrents/
│   │   ├── movies/       ← Radarr category
│   │   ├── tv/           ← Sonarr category
│   │   ├── music/
│   │   └── watch/        ← drop .torrent files here
│   └── media/
│       ├── movies/       ← Radarr root folder
│       ├── tv/           ← Sonarr root folder
│       └── music/
├── docker-compose.yml
├── docker-compose.vpn.yml
├── docker-compose.novpn.yml
└── .env
```

## Status & Management

```bash
./status.sh              # dashboard: Colima VM, containers, VPN, downloads, disk, queue
```

```bash
cd ~/media-server
docker compose logs -f                          # view logs
docker compose restart                          # restart all
docker compose pull && docker compose up -d     # update images
colima status                                   # VM info
pmset -g                                        # power settings
```

## After Setup

1. **Add indexers** — Prowlarr → Indexers → Add Indexer (they auto-sync to Sonarr/Radarr)
2. **Add movies** — Radarr → Movies → Add New
3. **Add TV shows** — Sonarr → Series → Add New
4. **Enable auto-login** — System Preferences → Users & Groups → Login Options
5. **Keep plugged in** — required for lid-closed (clamshell) mode

## Technical Details

- **Docker runtime**: Colima (Lima VM). Uses `vz` + `virtiofs` on macOS 13+, falls back to `qemu` + `sshfs` on Monterey.
- **Compose env vars**: PUID, PGID, TZ sourced from `.env`.
- **Networking**: Plex runs `network_mode: host` for local discovery. With VPN enabled, Transmission shares Gluetun's network namespace.
- **FlareSolverr**: Registered as an indexer proxy in Prowlarr. Tag individual indexers with `flaresolverr` to route them through it.
- **Power**: `pmset disablesleep 1`, `womp 1` (Wake-on-LAN), `hibernatemode 0`. Machine stays on with lid closed.
