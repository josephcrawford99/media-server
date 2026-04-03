#!/usr/bin/env bash
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────
MEDIA_ROOT="${1:-$HOME/media-server}"
TZ="America/New_York"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bold=$(tput bold); reset=$(tput sgr0)
step() { echo; echo "${bold}▸ $1${reset}"; }

# ── Prerequisites ─────────────────────────────────────────────
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

# ── Install packages ──────────────────────────────────────────
step "Installing colima, docker, docker-compose-plugin via MacPorts"
sudo port install colima docker docker-compose-plugin

# ── Colima VM ─────────────────────────────────────────────────
step "Colima VM resource allocation"
TOTAL_CPU=$(sysctl -n hw.ncpu)
TOTAL_MEM=$(( $(sysctl -n hw.memsize) / 1073741824 ))  # bytes → GB
DEFAULT_CPU=$(( TOTAL_CPU > 2 ? TOTAL_CPU - 2 : 1 ))
DEFAULT_MEM=$(( TOTAL_MEM > 4 ? TOTAL_MEM - 4 : 2 ))

echo "This machine has ${bold}${TOTAL_CPU} CPUs${reset} and ${bold}${TOTAL_MEM}GB RAM${reset}."
echo "Recommended: leave 2 CPUs and 4GB for macOS."
echo ""
read -rp "CPUs for Colima VM [${DEFAULT_CPU}]: " COLIMA_CPU
COLIMA_CPU="${COLIMA_CPU:-$DEFAULT_CPU}"
read -rp "Memory (GB) for Colima VM [${DEFAULT_MEM}]: " COLIMA_MEM
COLIMA_MEM="${COLIMA_MEM:-$DEFAULT_MEM}"
read -rp "Disk (GB) for Colima VM [60]: " COLIMA_DISK
COLIMA_DISK="${COLIMA_DISK:-60}"
echo "Allocating ${COLIMA_CPU} CPUs, ${COLIMA_MEM}GB RAM, ${COLIMA_DISK}GB disk."

step "Starting Colima"
if colima status &>/dev/null; then
    echo "Colima is already running. Restarting with new resource settings..."
    colima stop
fi
MACOS_VER=$(sw_vers -productVersion | cut -d. -f1)
COLIMA_MOUNT="sshfs"
COLIMA_VM_TYPE=()
if [ "$MACOS_VER" -ge 13 ] 2>/dev/null; then
    COLIMA_MOUNT="virtiofs"
    COLIMA_VM_TYPE=(--vm-type vz)
    echo "macOS $MACOS_VER detected — using vz + virtiofs."
else
    echo "macOS $MACOS_VER detected — using qemu + sshfs."
fi
colima start \
    --cpu "$COLIMA_CPU" \
    --memory "$COLIMA_MEM" \
    --disk "$COLIMA_DISK" \
    --mount-type "$COLIMA_MOUNT" \
    "${COLIMA_VM_TYPE[@]}"

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

# ── Directories ───────────────────────────────────────────────
# TRaSH Guides pattern: single /data root enables hardlinks
# when Sonarr/Radarr move files from torrents/ to media/
step "Creating directory structure"
mkdir -p "$MEDIA_ROOT"/config/{plex,transmission,prowlarr,sonarr,radarr}
mkdir -p "$MEDIA_ROOT"/data/torrents/{movies,tv,music,watch}
mkdir -p "$MEDIA_ROOT"/data/media/{movies,tv,music}

# ── Deploy runtime files ──────────────────────────────────────
step "Deploying runtime files to $MEDIA_ROOT"
RUNTIME_FILES=(docker-compose.yml docker-compose.vpn.yml docker-compose.novpn.yml transmission-settings.json)
if [ "$SCRIPT_DIR" != "$MEDIA_ROOT" ]; then
    for f in "${RUNTIME_FILES[@]}"; do
        cp "$SCRIPT_DIR/$f" "$MEDIA_ROOT/$f"
    done
    cp -r "$SCRIPT_DIR/dashboard" "$MEDIA_ROOT/dashboard"
    echo "Copied compose, config, and dashboard files to $MEDIA_ROOT"
else
    echo "Repo is the runtime directory — no copy needed."
fi

# ── Environment (.env) ────────────────────────────────────────
step "Configuring .env"
ENV_FILE="$MEDIA_ROOT/.env"
EXISTING_VPN=""
if [ -f "$ENV_FILE" ]; then
    EXISTING_VPN=$(grep -E '^WIREGUARD_' "$ENV_FILE" 2>/dev/null || true)
fi
cat > "$ENV_FILE" <<EOF
PUID=$(id -u)
PGID=$(id -g)
TZ=$TZ
EOF
if [ -n "$EXISTING_VPN" ]; then
    echo "$EXISTING_VPN" >> "$ENV_FILE"
fi
echo "Wrote PUID=$(id -u), PGID=$(id -g), TZ=$TZ to .env"

# ── VPN setup (optional) ─────────────────────────────────────
step "VPN setup (optional)"
USE_VPN=false
if grep -q 'WIREGUARD_PRIVATE_KEY=.' "$ENV_FILE" 2>/dev/null; then
    echo "Mullvad VPN already configured."
    USE_VPN=true
else
    read -rp "Set up Mullvad VPN for Transmission? (y/N): " VPN_CHOICE
    if [ "$VPN_CHOICE" = "y" ] || [ "$VPN_CHOICE" = "Y" ]; then
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
                WG_ADDRESS=$(echo "$RESPONSE" | cut -d',' -f1)
                echo "WIREGUARD_PRIVATE_KEY=$PRIVKEY" >> "$ENV_FILE"
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

# ── Plex claim token ─────────────────────────────────────────
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

# ── Power management ─────────────────────────────────────────
step "Configuring power management (requires sudo)"
sudo pmset -a disablesleep 1     # never sleep, even with lid closed
sudo pmset -a displaysleep 2     # turn off display after 2 min
sudo pmset -a womp 1             # wake on LAN (magic packet)
sudo pmset -a tcpkeepalive 1     # maintain network connections
sudo pmset -a powernap 0         # no DarkWake maintenance cycles
sudo pmset -a hibernatemode 0    # no hibernate to disk
echo "Power settings applied."

# ── Spotlight ─────────────────────────────────────────────────
step "Disabling Spotlight indexing on data directory"
touch "$MEDIA_ROOT/data/.metadata_never_index" 2>/dev/null || true
echo "Done."

# ── LaunchAgent ───────────────────────────────────────────────
step "Installing LaunchAgent for Colima auto-start"
LAUNCH_DIR="$HOME/Library/LaunchAgents"
mkdir -p "$LAUNCH_DIR"

COLIMA_PATH="$(which colima)"
PLIST_DST="$LAUNCH_DIR/com.user.colima.plist"

sed -e "s|/opt/local/bin/colima|$COLIMA_PATH|g" \
    -e "s|<string>2</string><!-- cpu -->|<string>$COLIMA_CPU</string><!-- cpu -->|" \
    -e "s|<string>2</string><!-- mem -->|<string>$COLIMA_MEM</string><!-- mem -->|" \
    -e "s|<string>60</string><!-- disk -->|<string>$COLIMA_DISK</string><!-- disk -->|" \
    "$SCRIPT_DIR/com.user.colima.plist" > "$PLIST_DST"
launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl load "$PLIST_DST"
echo "LaunchAgent installed."

# ── Start containers ──────────────────────────────────────────
step "Pulling and starting containers"
cd "$MEDIA_ROOT"

mkdir -p "$MEDIA_ROOT/config/transmission" "$MEDIA_ROOT/data/torrents/incomplete"
if [ ! -f "$MEDIA_ROOT/config/transmission/settings.json" ]; then
    cp "$SCRIPT_DIR/transmission-settings.json" "$MEDIA_ROOT/config/transmission/settings.json"
    echo "Transmission pre-configured: /data/torrents, no seeding."
fi

if [ "$USE_VPN" = true ]; then
    COMPOSE_CMD="docker compose -f docker-compose.yml -f docker-compose.vpn.yml"
    echo "VPN enabled — routing Transmission through Mullvad."
else
    COMPOSE_CMD="docker compose -f docker-compose.yml -f docker-compose.novpn.yml"
fi
$COMPOSE_CMD pull
$COMPOSE_CMD up -d

# ── Configure *arr stack ──────────────────────────────────────
step "Configuring *arr stack connections"

wait_and_get_key() {
    local name="$1" url="$2" config="$3"
    echo "Waiting for $name..."
    for i in $(seq 1 60); do
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

add_root_folder() {
    local name="$1" url="$2" key="$3" path="$4"
    curl -s -X POST "$url/api/v3/rootfolder" \
        -H "X-Api-Key: $key" \
        -H "Content-Type: application/json" \
        -d "{\"path\": \"$path\"}" >/dev/null 2>&1 && echo "  $name: Root folder set to $path" \
        || echo "  $name: Warning — set root folder manually in UI."
}

PROWLARR_KEY=$(wait_and_get_key "Prowlarr" "http://localhost:9696" "$MEDIA_ROOT/config/prowlarr/config.xml")
SONARR_KEY=$(wait_and_get_key "Sonarr" "http://localhost:8989" "$MEDIA_ROOT/config/sonarr/config.xml")
RADARR_KEY=$(wait_and_get_key "Radarr" "http://localhost:7878" "$MEDIA_ROOT/config/radarr/config.xml")

echo "Waiting for FlareSolverr..."
for i in $(seq 1 30); do
    if curl -s -o /dev/null -w '%{http_code}' "http://localhost:8191" 2>/dev/null | grep -q "200\|405"; then
        echo "  FlareSolverr is up."
        break
    fi
    sleep 3
done

if [ -n "$PROWLARR_KEY" ]; then
    FS_TAG_ID=$(curl -s -X POST "http://localhost:9696/api/v1/tag" \
        -H "X-Api-Key: $PROWLARR_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"label\": \"flaresolverr\"}" 2>/dev/null | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
    if [ -z "$FS_TAG_ID" ]; then
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

PLEX_PREFS="$MEDIA_ROOT/config/plex/Library/Application Support/Plex Media Server/Preferences.xml"
PLEX_TOKEN=""
if [ -f "$PLEX_PREFS" ]; then
    PLEX_TOKEN=$(grep -o 'PlexOnlineToken="[^"]*"' "$PLEX_PREFS" | cut -d'"' -f2)
fi
if [ -n "$PLEX_TOKEN" ]; then
    add_plex_notify() {
        local name="$1" url="$2" key="$3"
        curl -s -X POST "$url/api/v3/notification" \
            -H "X-Api-Key: $key" \
            -H "Content-Type: application/json" \
            -d "{
                \"name\": \"Plex\",
                \"implementation\": \"PlexServer\",
                \"configContract\": \"PlexServerSettings\",
                \"onDownload\": true,
                \"onUpgrade\": true,
                \"onRename\": true,
                \"onEpisodeFileDelete\": true,
                \"onMovieFileDelete\": true,
                \"fields\": [
                    {\"name\": \"host\", \"value\": \"host.docker.internal\"},
                    {\"name\": \"port\", \"value\": 32400},
                    {\"name\": \"useSsl\", \"value\": false},
                    {\"name\": \"authToken\", \"value\": \"$PLEX_TOKEN\"},
                    {\"name\": \"updateLibrary\", \"value\": true}
                ]
            }" >/dev/null 2>&1 && echo "  $name → Plex: library scan on import." \
            || echo "  $name → Plex: Warning — add manually in Settings → Connect."
    }
    [ -n "$SONARR_KEY" ] && add_plex_notify "Sonarr" "http://localhost:8989" "$SONARR_KEY"
    [ -n "$RADARR_KEY" ] && add_plex_notify "Radarr" "http://localhost:7878" "$RADARR_KEY"
else
    echo "  Plex not claimed yet — add Plex notification manually in Sonarr/Radarr Settings → Connect."
fi

# ── Health checks ─────────────────────────────────────────────
# These never abort the script — failures are warnings only
step "Running health checks"
HEALTH_OK=true

check_http() {
    local name="$1" url="$2"
    if curl -s -o /dev/null -w '%{http_code}' "$url" 2>/dev/null | grep -q "200\|401\|302"; then
        echo "  ✓ $name is reachable"
    else
        echo "  ✗ $name is NOT reachable at $url"
        HEALTH_OK=false
    fi
}

check_http "Dashboard" "http://localhost:80"
check_http "Plex" "http://localhost:32400/web"
check_http "Sonarr" "http://localhost:8989"
check_http "Radarr" "http://localhost:7878"
check_http "Prowlarr" "http://localhost:9696"
check_http "FlareSolverr" "http://localhost:8191"
check_http "Transmission" "http://localhost:9091/transmission/web/"

# API checks with retries — apps may still be committing config
check_api() {
    local label="$1" check_cmd="$2" fail_msg="$3"
    for attempt in 1 2 3; do
        if eval "$check_cmd" 2>/dev/null; then
            echo "  ✓ $label"
            return 0
        fi
        [ "$attempt" -lt 3 ] && sleep 3
    done
    echo "  ✗ $fail_msg"
    HEALTH_OK=false
}

if [ -n "$SONARR_KEY" ]; then
    check_api "Sonarr → Transmission connected" \
        "curl -s 'http://localhost:8989/api/v3/downloadclient' -H 'X-Api-Key: $SONARR_KEY' | python3 -c \"import sys,json;clients=json.load(sys.stdin);assert any(c.get('enable') for c in clients)\"" \
        "Sonarr has no active download client"
fi

if [ -n "$RADARR_KEY" ]; then
    check_api "Radarr → Transmission connected" \
        "curl -s 'http://localhost:7878/api/v3/downloadclient' -H 'X-Api-Key: $RADARR_KEY' | python3 -c \"import sys,json;clients=json.load(sys.stdin);assert any(c.get('enable') for c in clients)\"" \
        "Radarr has no active download client"
fi

if [ -n "$PROWLARR_KEY" ]; then
    check_api "Prowlarr → Sonarr/Radarr sync configured" \
        "[ \$(curl -s 'http://localhost:9696/api/v1/applications' -H 'X-Api-Key: $PROWLARR_KEY' | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))') -ge 2 ]" \
        "Prowlarr app sync missing (expected 2+ apps)"
fi

if [ "$USE_VPN" = true ]; then
    check_api "VPN active" \
        "docker exec gluetun wget -qO- https://am.i.mullvad.net/ip" \
        "VPN not working — Transmission may be exposed"
fi

if [ "$HEALTH_OK" = true ]; then
    echo ""
    echo "  All checks passed."
else
    echo ""
    echo "  Some checks failed — review above."
fi

# ── Summary ───────────────────────────────────────────────────
step "Done! Your media server is running."
LOCAL_IP=$(ipconfig getifaddr en0 2>/dev/null || echo "<your-ip>")
MAC_ADDR=$(ifconfig en0 2>/dev/null | awk '/ether/{print $2}' || echo "<unknown>")

cat <<SUMMARY

  Dashboard:     http://${LOCAL_IP}/ (links to all services)

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

# ── Tailscale (optional remote access) ────────────────────────
# Last step — everything above works on the local network already.
# Tailscale lets you access all services from anywhere.
step "Remote access via Tailscale (optional)"
if command -v tailscale &>/dev/null && tailscale status &>/dev/null; then
    TS_IP=$(tailscale ip -4 2>/dev/null || true)
    echo "Tailscale is already connected. IP: $TS_IP"
    echo "  Dashboard: http://${TS_IP}/"
    echo "  All services are accessible remotely via Tailscale."
else
    read -rp "Set up Tailscale for remote access? (y/N): " TS_CHOICE
    if [ "$TS_CHOICE" = "y" ] || [ "$TS_CHOICE" = "Y" ]; then
        if ! command -v tailscale &>/dev/null; then
            echo "Installing Tailscale via MacPorts..."
            sudo port install tailscale
        fi
        if ! pgrep -x tailscaled &>/dev/null; then
            echo "Starting tailscaled daemon..."
            sudo port load tailscale
            sleep 2
        fi
        echo ""
        echo "Authenticating — follow the URL below to sign in:"
        echo ""
        sudo tailscale up
        echo ""
        TS_IP=$(tailscale ip -4 2>/dev/null || true)
        echo "Tailscale connected! IP: $TS_IP"
        echo "  Dashboard: http://${TS_IP}/"
        echo ""
        echo "  Install Tailscale on your other devices: https://tailscale.com/download"
        echo "  Sign in with the same account for remote access to everything."
    else
        echo "Skipped. You can set up Tailscale later by re-running setup."
    fi
fi
