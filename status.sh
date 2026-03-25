#!/usr/bin/env bash
# Quick status check for the media server stack

export PATH=/opt/local/bin:$PATH
export DOCKER_HOST="unix://${HOME}/.colima/default/docker.sock"
MEDIA_ROOT="${1:-$HOME/media-server}"

bold=$(tput bold); dim=$(tput setaf 8); reset=$(tput sgr0)

echo "${bold}── Media Server Status ──${reset}"
echo ""

# Containers
echo "${bold}Containers${reset}"
docker ps -a --format "  {{.Names}}: {{.Status}}" 2>/dev/null | sort
echo ""

# VPN
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q gluetun; then
    VPN_IP=$(docker exec gluetun wget -qO- https://am.i.mullvad.net/ip 2>/dev/null)
    echo "${bold}VPN${reset}"
    echo "  IP: ${VPN_IP:-unknown}"
    echo ""
fi

# Transmission
echo "${bold}Downloads${reset}"
docker exec transmission transmission-remote localhost:9091 -l 2>/dev/null | tail -n +2 | sed 's/^/  /'
echo ""

# Disk
echo "${bold}Disk${reset}"
DISK_AVAIL=$(df -h "$MEDIA_ROOT" 2>/dev/null | awk 'NR==2{print $4}')
DISK_USED=$(du -sh "$MEDIA_ROOT/data" 2>/dev/null | cut -f1)
echo "  Available: ${DISK_AVAIL:-?}"
echo "  Media data: ${DISK_USED:-?}"
echo ""

# Sonarr/Radarr queue
SKEY=$(sed -n 's/.*<ApiKey>\(.*\)<\/ApiKey>.*/\1/p' "$MEDIA_ROOT/config/sonarr/config.xml" 2>/dev/null)
RKEY=$(sed -n 's/.*<ApiKey>\(.*\)<\/ApiKey>.*/\1/p' "$MEDIA_ROOT/config/radarr/config.xml" 2>/dev/null)
if [ -n "$SKEY" ] || [ -n "$RKEY" ]; then
    echo "${bold}Queue${reset}"
    if [ -n "$SKEY" ]; then
        SQ=$(curl -s "http://localhost:8989/api/v3/queue?pageSize=1" -H "X-Api-Key: $SKEY" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('totalRecords',0))" 2>/dev/null)
        echo "  Sonarr: ${SQ:-0} items"
    fi
    if [ -n "$RKEY" ]; then
        RQ=$(curl -s "http://localhost:7878/api/v3/queue?pageSize=1" -H "X-Api-Key: $RKEY" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('totalRecords',0))" 2>/dev/null)
        echo "  Radarr: ${RQ:-0} items"
    fi
fi
