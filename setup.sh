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

# ── 5b. Optional VPN setup (Mullvad WireGuard) ───────────────
step "VPN setup (optional)"
ENV_FILE="$MEDIA_ROOT/.env"
USE_VPN=false
if [ -f "$ENV_FILE" ] && grep -q 'WIREGUARD_PRIVATE_KEY=.' "$ENV_FILE"; then
    echo "Mullvad VPN already configured."
    USE_VPN=true
else
    read -rp "Set up Mullvad VPN for Transmission? (y/N): " VPN_CHOICE
    if [ "$VPN_CHOICE" = "y" ] || [ "$VPN_CHOICE" = "Y" ]; then
        # Install wireguard-tools if not present
        if ! command -v wg &>/dev/null; then
            echo "Installing wireguard-tools..."
            sudo port install wireguard-tools
        fi
        read -rp "Enter your Mullvad account number: " MULLVAD_ACCOUNT
        if [ -n "$MULLVAD_ACCOUNT" ]; then
            echo "Generating WireGuard keys..."
            PRIVKEY=$(wg genkey)
            PUBKEY=$(echo "$PRIVKEY" | wg pubkey)
            echo "Registering key with Mullvad..."
            RESPONSE=$(curl -s -X POST "https://api.mullvad.net/wg/" \
                -d account="$MULLVAD_ACCOUNT" \
                -d pubkey="$PUBKEY")
            if echo "$RESPONSE" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
                # Mullvad returns IPv4,IPv6 — gluetun only supports IPv4
                WG_ADDRESS=$(echo "$RESPONSE" | cut -d',' -f1)
                echo "WIREGUARD_PRIVATE_KEY=$PRIVKEY" > "$ENV_FILE"
                echo "WIREGUARD_ADDRESSES=$WG_ADDRESS" >> "$ENV_FILE"
                echo "VPN configured. Address: $WG_ADDRESS"
                USE_VPN=true
            else
                echo "Warning: Mullvad API error: $RESPONSE"
                echo "You can configure manually in $ENV_FILE"
            fi
        fi
    else
        echo "Skipped. You can enable VPN later by re-running setup."
    fi
fi

# ── 6. Plex claim token ───────────────────────────────────────
step "Plex claim token"
PLEX_PREFS="$MEDIA_ROOT/config/plex/Library/Application Support/Plex Media Server/Preferences.xml"
if [ -f "$PLEX_PREFS" ] && grep -q 'PlexOnlineToken' "$PLEX_PREFS"; then
    echo "Plex is already claimed. Skipping."
else
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
fi

# ── 7. Power management ───────────────────────────────────────
# Goal: machine never sleeps (it's a server), display off when idle,
# wake on LAN for remote access, survive lid closed.
step "Configuring power management (requires sudo)"
sudo pmset -a disablesleep 1     # never sleep, even with lid closed
sudo pmset -a displaysleep 2     # turn off display after 2 min
sudo pmset -a womp 1             # wake on LAN (magic packet)
sudo pmset -a tcpkeepalive 1     # maintain network connections
sudo pmset -a powernap 0         # no DarkWake maintenance cycles
sudo pmset -a hibernatemode 0    # no hibernate to disk
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
if [ "$USE_VPN" = true ]; then
    COMPOSE_CMD="docker compose -f docker-compose.yml -f docker-compose.vpn.yml"
    echo "VPN enabled — routing Transmission through Mullvad."
else
    COMPOSE_CMD="docker compose -f docker-compose.yml -f docker-compose.novpn.yml"
fi
$COMPOSE_CMD pull
$COMPOSE_CMD up -d

# ── 10a. Fix Transmission download paths ─────────────────────
step "Configuring Transmission download directory"
TRANS_SETTINGS="$MEDIA_ROOT/config/transmission/settings.json"
# Wait for Transmission to create its settings file
for i in $(seq 1 30); do
    [ -f "$TRANS_SETTINGS" ] && break
    sleep 2
done
if [ -f "$TRANS_SETTINGS" ]; then
    docker compose stop transmission
    sed -i '' 's|/downloads/complete|/data/torrents|g' "$TRANS_SETTINGS"
    sed -i '' 's|/downloads/incomplete|/data/torrents/incomplete|g' "$TRANS_SETTINGS"
    mkdir -p "$MEDIA_ROOT/data/torrents/incomplete"
    docker compose start transmission
    echo "Transmission download dir set to /data/torrents"
fi

# ── 11. Configure *arr stack via API ──────────────────────────
step "Configuring *arr stack connections"

# Helper: wait for an app to respond, read its API key
wait_and_get_key() {
    local name="$1" url="$2" config="$3"
    echo "Waiting for $name..."
    for i in $(seq 1 60); do
        # Apps return various responses — just check for HTTP 200
        if curl -s -o /dev/null -w '%{http_code}' "$url/ping" 2>/dev/null | grep -q "200"; then
            echo "  $name is up."
            break
        fi
        sleep 3
    done
    if [ -f "$config" ]; then
        sed -n 's/.*<ApiKey>\(.*\)<\/ApiKey>.*/\1/p' "$config"
    fi
}

# Helper: add Transmission as download client
# When VPN is enabled, Transmission shares gluetun's network
TRANSMISSION_HOST="transmission"
if [ "$USE_VPN" = true ]; then
    TRANSMISSION_HOST="gluetun"
fi

add_transmission() {
    local name="$1" url="$2" key="$3" category="$4" api_ver="${5:-v3}"
    curl -s -X POST "$url/api/$api_ver/downloadclient" \
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
                {\"name\": \"host\", \"value\": \"$TRANSMISSION_HOST\"},
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

# Wait for FlareSolverr to be ready
echo "Waiting for FlareSolverr..."
for i in $(seq 1 30); do
    if curl -s -o /dev/null -w '%{http_code}' "http://localhost:8191" 2>/dev/null | grep -q "200\|405"; then
        echo "  FlareSolverr is up."
        break
    fi
    sleep 3
done

# Create 'flaresolverr' tag and add FlareSolverr proxy in Prowlarr
# Indexers tagged 'flaresolverr' will route through FlareSolverr to bypass Cloudflare
if [ -n "$PROWLARR_KEY" ]; then
    FS_TAG_ID=$(curl -s -X POST "http://localhost:9696/api/v1/tag" \
        -H "X-Api-Key: $PROWLARR_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"label\": \"flaresolverr\"}" 2>/dev/null | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
    if [ -z "$FS_TAG_ID" ]; then
        # Tag may already exist, fetch its id
        FS_TAG_ID=$(curl -s "http://localhost:9696/api/v1/tag" \
            -H "X-Api-Key: $PROWLARR_KEY" 2>/dev/null \
            | sed -n 's/.*"label":"flaresolverr".*"id":\([0-9]*\).*/\1/p; s/.*"id":\([0-9]*\).*"label":"flaresolverr".*/\1/p' | head -1)
    fi
    FS_TAGS="[]"
    [ -n "$FS_TAG_ID" ] && FS_TAGS="[$FS_TAG_ID]"

    curl -s -X POST "http://localhost:9696/api/v1/indexerProxy" \
        -H "X-Api-Key: $PROWLARR_KEY" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"FlareSolverr\",
            \"implementation\": \"FlareSolverr\",
            \"configContract\": \"FlareSolverrSettings\",
            \"tags\": $FS_TAGS,
            \"fields\": [
                {\"name\": \"host\", \"value\": \"http://flaresolverr:8191\"},
                {\"name\": \"requestTimeout\", \"value\": 60}
            ]
        }" >/dev/null 2>&1 && echo "  Prowlarr: FlareSolverr proxy added with tag 'flaresolverr'." \
        || echo "  Prowlarr: Warning — add FlareSolverr manually (Settings → Indexers → Indexer Proxies)."
    echo "  Tip: Tag indexers with 'flaresolverr' to route them through FlareSolverr."
fi

# Add Transmission as download client in each app
if [ -n "$PROWLARR_KEY" ]; then
    add_transmission "Prowlarr" "http://localhost:9696" "$PROWLARR_KEY" "" "v1"
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
    FlareSolverr:  http://${LOCAL_IP}:8191

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
