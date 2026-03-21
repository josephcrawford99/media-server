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
step "Installing colima, docker, docker-compose via MacPorts"
sudo port install colima docker docker-compose

# ── 3. Start Colima ───────────────────────────────────────────
step "Starting Colima (${COLIMA_CPU} CPU, ${COLIMA_MEM}GB RAM, ${COLIMA_DISK}GB disk)"
colima start \
    --cpu "$COLIMA_CPU" \
    --memory "$COLIMA_MEM" \
    --disk "$COLIMA_DISK" \
    --mount-type virtiofs

docker info >/dev/null 2>&1 || { echo "ERROR: Docker not responding"; exit 1; }
echo "Docker is running via Colima."

# ── 4. Create directories ─────────────────────────────────────
step "Creating media and config directories"
mkdir -p "$MEDIA_ROOT"/{config/{plex,transmission,prowlarr},media/{movies,tv,music,downloads/watch}}

# ── 5. Copy and patch docker-compose.yml ──────────────────────
step "Setting up docker-compose.yml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp "$SCRIPT_DIR/docker-compose.yml" "$MEDIA_ROOT/docker-compose.yml"

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

# ── 8. Disable Spotlight on media ─────────────────────────────
step "Disabling Spotlight indexing on media directory"
sudo mdutil -i off "$MEDIA_ROOT/media" 2>/dev/null || true

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
docker-compose pull
docker-compose up -d

# ── 11. Summary ────────────────────────────────────────────────
step "Done! Your media server is running."
LOCAL_IP=$(ipconfig getifaddr en0 2>/dev/null || echo "<your-ip>")
MAC_ADDR=$(ifconfig en0 2>/dev/null | awk '/ether/{print $2}' || echo "<unknown>")

cat <<SUMMARY

  Services:
    Plex:          http://${LOCAL_IP}:32400/web
    Transmission:  http://${LOCAL_IP}:9091
    Prowlarr:      http://${LOCAL_IP}:9696

  Directories:
    Media:   $MEDIA_ROOT/media/
    Config:  $MEDIA_ROOT/config/
    Compose: $MEDIA_ROOT/docker-compose.yml

  Wake on LAN:
    MAC address: ${MAC_ADDR}

  Management:
    cd $MEDIA_ROOT && docker-compose logs -f
    cd $MEDIA_ROOT && docker-compose restart
    cd $MEDIA_ROOT && docker-compose pull && docker-compose up -d
    colima status
    pmset -g

  Manual steps remaining:
    - Enable auto-login: System Preferences → Users & Groups → Login Options
    - Plug in power (required for clamshell/lid-closed mode)

SUMMARY

pmset -g
