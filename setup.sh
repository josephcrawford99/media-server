#!/usr/bin/env bash
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────
COLIMA_CPU=2
COLIMA_MEM=2
COLIMA_DISK=60
MEDIA_ROOT="$HOME/media-server"
TZ="America/New_York"

bold=$(tput bold); reset=$(tput sgr0)
step() { echo; echo "${bold}▸ $1${reset}"; }

# ── 1. Prerequisites ──────────────────────────────────────────
step "Checking prerequisites"

if ! xcode-select -p &>/dev/null; then
    echo "Xcode Command Line Tools not found."
    echo "Run: xcode-select --install"
    echo "Then re-run this script."
    exit 1
fi
echo "Xcode CLI Tools: OK"

if ! command -v port &>/dev/null; then
    echo "MacPorts not found."
    echo "Download the Monterey installer from: https://www.macports.org/install.php"
    echo "Install it, then re-run this script."
    exit 1
fi
echo "MacPorts: OK"

# ── 2. Install packages ───────────────────────────────────────
step "Installing colima, docker, docker-compose-plugin via MacPorts"
sudo port install colima docker docker-compose-plugin

# ── 3. Start Colima ───────────────────────────────────────────
step "Starting Colima (${COLIMA_CPU} CPU, ${COLIMA_MEM}GB RAM, ${COLIMA_DISK}GB disk)"
colima start \
    --cpu "$COLIMA_CPU" \
    --memory "$COLIMA_MEM" \
    --disk "$COLIMA_DISK" \
    --mount-type virtiofs

# Ensure Docker CLI can reach Colima's socket
export DOCKER_HOST="unix://${HOME}/.colima/default/docker.sock"

docker info >/dev/null 2>&1 || { echo "ERROR: Docker not responding"; exit 1; }
echo "Docker is running via Colima."

# Persist DOCKER_HOST for future shell sessions
ZSHRC="$HOME/.zshrc"
if [ -f "$ZSHRC" ] && grep -q 'DOCKER_HOST.*colima' "$ZSHRC"; then
    echo "DOCKER_HOST already in .zshrc"
else
    echo '' >> "$ZSHRC"
    echo '# Docker via Colima' >> "$ZSHRC"
    echo 'export DOCKER_HOST="unix://${HOME}/.colima/default/docker.sock"' >> "$ZSHRC"
    echo "Added DOCKER_HOST to .zshrc"
fi

# ── 4. Create directories ─────────────────────────────────────
# TRaSH Guides pattern: single /data root enables hardlinks
# when Sonarr/Radarr move files from torrents/ to media/
step "Creating directory structure"
mkdir -p "$MEDIA_ROOT"/config/{plex,transmission,prowlarr,sonarr,radarr}
mkdir -p "$MEDIA_ROOT"/data/torrents/{movies,tv,music,watch}
mkdir -p "$MEDIA_ROOT"/data/media/{movies,tv,music}

# ── 5. Copy and patch docker-compose.yml ──────────────────────
step "Setting up docker-compose.yml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$SCRIPT_DIR" != "$MEDIA_ROOT" ]; then
    cp "$SCRIPT_DIR/docker-compose.yml" "$MEDIA_ROOT/docker-compose.yml"
fi

CURRENT_UID=$(id -u)
CURRENT_GID=$(id -g)
if [ "$CURRENT_UID" != "501" ] || [ "$CURRENT_GID" != "20" ]; then
    echo "Patching PUID=$CURRENT_UID, PGID=$CURRENT_GID"
    sed -i '' "s/PUID=501/PUID=$CURRENT_UID/g" "$MEDIA_ROOT/docker-compose.yml"
    sed -i '' "s/PGID=20/PGID=$CURRENT_GID/g" "$MEDIA_ROOT/docker-compose.yml"
fi
sed -i '' "s|TZ=America/New_York|TZ=$TZ|g" "$MEDIA_ROOT/docker-compose.yml"

# ── 6. Plex claim token ───────────────────────────────────────
step "Plex claim token"
echo "To link this Plex server to your account, you need a claim token."
echo ""
echo "  1. Open this URL in your browser:"
echo "     https://www.plex.tv/claim/"
echo ""
echo "  2. Sign in and copy the claim token (starts with 'claim-')"
echo ""
read -rp "Paste your Plex claim token here (or press Enter to skip): " PLEX_CLAIM
if [ -n "$PLEX_CLAIM" ]; then
    export PLEX_CLAIM
    echo "Claim token set."
else
    echo "Skipped. You can claim later at http://<server-ip>:32400/web"
fi

# ── 7. Power management ───────────────────────────────────────
step "Configuring power management (requires sudo)"
sudo pmset -a displaysleep 2
sudo pmset -a sleep 0
sudo pmset -a womp 1
sudo pmset -a tcpkeepalive 1
sudo pmset -a hibernatemode 0
sudo pmset -a standby 0
sudo pmset -a autopoweroff 0
echo "Power settings applied. Verify with: pmset -g"

# ── 8. Disable Spotlight on data ──────────────────────────────
step "Disabling Spotlight indexing on data directory"
sudo mdutil -i off "$MEDIA_ROOT/data" 2>/dev/null || true

# ── 9. LaunchAgent for auto-start ─────────────────────────────
step "Installing LaunchAgent for Colima auto-start"
LAUNCH_DIR="$HOME/Library/LaunchAgents"
mkdir -p "$LAUNCH_DIR"

COLIMA_PATH="$(which colima)"
PLIST_DST="$LAUNCH_DIR/com.user.colima.plist"

sed "s|/opt/local/bin/colima|$COLIMA_PATH|g" "$SCRIPT_DIR/com.user.colima.plist" > "$PLIST_DST"
launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl load "$PLIST_DST"
echo "LaunchAgent installed."

# ── 10. Start containers ──────────────────────────────────────
step "Pulling and starting containers"
cd "$MEDIA_ROOT"
docker compose pull
docker compose up -d

# ── 11. Configure *arr stack via API ──────────────────────────
step "Configuring *arr stack connections"

# Helper: wait for an app to respond, read its API key
wait_and_get_key() {
    local name="$1" url="$2" config="$3"
    echo "Waiting for $name..."
    for i in $(seq 1 30); do
        curl -s "$url/ping" 2>/dev/null | grep -q "Pong" && break
        sleep 2
    done
    if [ -f "$config" ]; then
        sed -n 's/.*<ApiKey>\(.*\)<\/ApiKey>.*/\1/p' "$config"
    fi
}

# Helper: add Transmission as download client
add_transmission() {
    local name="$1" url="$2" key="$3" category="$4"
    curl -s -X POST "$url/api/v1/downloadclient" \
        -H "X-Api-Key: $key" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"Transmission\",
            \"implementation\": \"Transmission\",
            \"configContract\": \"TransmissionSettings\",
            \"protocol\": \"torrent\",
            \"enable\": true,
            \"priority\": 1,
            \"fields\": [
                {\"name\": \"host\", \"value\": \"transmission\"},
                {\"name\": \"port\", \"value\": 9091},
                {\"name\": \"urlBase\", \"value\": \"/transmission/\"},
                {\"name\": \"tvCategory\", \"value\": \"$category\"},
                {\"name\": \"movieCategory\", \"value\": \"$category\"},
                {\"name\": \"category\", \"value\": \"$category\"}
            ]
        }" >/dev/null 2>&1 && echo "  $name: Transmission connected." \
        || echo "  $name: Warning — add Transmission manually in UI."
}

# Helper: add root folder
add_root_folder() {
    local name="$1" url="$2" key="$3" path="$4"
    curl -s -X POST "$url/api/v3/rootfolder" \
        -H "X-Api-Key: $key" \
        -H "Content-Type: application/json" \
        -d "{\"path\": \"$path\"}" >/dev/null 2>&1 && echo "  $name: Root folder set to $path" \
        || echo "  $name: Warning — set root folder manually in UI."
}

# Get API keys for all apps
PROWLARR_KEY=$(wait_and_get_key "Prowlarr" "http://localhost:9696" "$MEDIA_ROOT/config/prowlarr/config.xml")
SONARR_KEY=$(wait_and_get_key "Sonarr" "http://localhost:8989" "$MEDIA_ROOT/config/sonarr/config.xml")
RADARR_KEY=$(wait_and_get_key "Radarr" "http://localhost:7878" "$MEDIA_ROOT/config/radarr/config.xml")

# Add Transmission as download client in each app
if [ -n "$PROWLARR_KEY" ]; then
    add_transmission "Prowlarr" "http://localhost:9696" "$PROWLARR_KEY" ""
fi
if [ -n "$SONARR_KEY" ]; then
    add_transmission "Sonarr" "http://localhost:8989" "$SONARR_KEY" "tv"
    add_root_folder "Sonarr" "http://localhost:8989" "$SONARR_KEY" "/data/media/tv"
fi
if [ -n "$RADARR_KEY" ]; then
    add_transmission "Radarr" "http://localhost:7878" "$RADARR_KEY" "movies"
    add_root_folder "Radarr" "http://localhost:7878" "$RADARR_KEY" "/data/media/movies"
fi

# Connect Prowlarr → Sonarr and Radarr (sync indexers)
if [ -n "$PROWLARR_KEY" ] && [ -n "$SONARR_KEY" ]; then
    curl -s -X POST "http://localhost:9696/api/v1/applications" \
        -H "X-Api-Key: $PROWLARR_KEY" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"Sonarr\",
            \"implementation\": \"Sonarr\",
            \"configContract\": \"SonarrSettings\",
            \"syncLevel\": \"fullSync\",
            \"fields\": [
                {\"name\": \"prowlarrUrl\", \"value\": \"http://prowlarr:9696\"},
                {\"name\": \"baseUrl\", \"value\": \"http://sonarr:8989\"},
                {\"name\": \"apiKey\", \"value\": \"$SONARR_KEY\"}
            ]
        }" >/dev/null 2>&1 && echo "  Prowlarr → Sonarr: indexer sync enabled." \
        || echo "  Prowlarr → Sonarr: Warning — connect manually in Prowlarr UI."
fi
if [ -n "$PROWLARR_KEY" ] && [ -n "$RADARR_KEY" ]; then
    curl -s -X POST "http://localhost:9696/api/v1/applications" \
        -H "X-Api-Key: $PROWLARR_KEY" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"Radarr\",
            \"implementation\": \"Radarr\",
            \"configContract\": \"RadarrSettings\",
            \"syncLevel\": \"fullSync\",
            \"fields\": [
                {\"name\": \"prowlarrUrl\", \"value\": \"http://prowlarr:9696\"},
                {\"name\": \"baseUrl\", \"value\": \"http://radarr:7878\"},
                {\"name\": \"apiKey\", \"value\": \"$RADARR_KEY\"}
            ]
        }" >/dev/null 2>&1 && echo "  Prowlarr → Radarr: indexer sync enabled." \
        || echo "  Prowlarr → Radarr: Warning — connect manually in Prowlarr UI."
fi

# ── 12. Summary ────────────────────────────────────────────────
step "Done! Your media server is running."
LOCAL_IP=$(ipconfig getifaddr en0 2>/dev/null || echo "<your-ip>")
MAC_ADDR=$(ifconfig en0 2>/dev/null | awk '/ether/{print $2}' || echo "<unknown>")

cat <<SUMMARY

  Services:
    Plex:          http://${LOCAL_IP}:32400/web
    Sonarr (TV):   http://${LOCAL_IP}:8989
    Radarr (Film): http://${LOCAL_IP}:7878
    Prowlarr:      http://${LOCAL_IP}:9696
    Transmission:  http://${LOCAL_IP}:9091

  Directories (TRaSH Guides pattern):
    Torrents:  $MEDIA_ROOT/data/torrents/
    Media:     $MEDIA_ROOT/data/media/
    Config:    $MEDIA_ROOT/config/
    Watch dir: $MEDIA_ROOT/data/torrents/watch/

  Wake on LAN:
    MAC address: ${MAC_ADDR}

  Next steps:
    1. Open Prowlarr at http://${LOCAL_IP}:9696
       → Indexers → Add Indexer → pick your trackers
    2. Open Radarr at http://${LOCAL_IP}:7878
       → Movies → Add New → search and add movies
    3. Open Sonarr at http://${LOCAL_IP}:8989
       → Series → Add New → search and add TV shows
    4. Downloads go to data/torrents/, then hardlink to data/media/
       Plex picks them up automatically.

  Management:
    cd $MEDIA_ROOT && docker compose logs -f
    cd $MEDIA_ROOT && docker compose restart
    cd $MEDIA_ROOT && docker compose pull && docker compose up -d
    colima status
    pmset -g

  Manual steps remaining:
    - Enable auto-login: System Preferences → Users & Groups → Login Options
    - Plug in power (required for clamshell/lid-closed mode)

SUMMARY

pmset -g
