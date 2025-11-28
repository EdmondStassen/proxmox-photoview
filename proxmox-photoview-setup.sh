#!/bin/bash
# Photoview Proxmox LXC setup helper

set -e

########## KLEUREN / HULPFUNCTIES ##########

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m' # No Color

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

ask_default() {
  # $1 = vraag, $2 = default
  local prompt default answer
  prompt="$1"
  default="$2"
  read -rp "$prompt [$default]: " answer
  echo "${answer:-$default}"
}

########## BASISCHECKS ##########

if [ "$(id -u)" -ne 0 ]; then
  error "Dit script moet als root worden uitgevoerd op de Proxmox host."
  exit 1
fi

if ! command -v pct >/dev/null 2>&1; then
  error "pct command niet gevonden. Dit script is bedoeld voor Proxmox VE."
  exit 1
fi

if ! command -v qm >/dev/null 2>&1; then
  warn "qm command niet gevonden. Automatische CTID-bepaling gebruikt nu alleen LXC ID's."
fi

########## FUNCTIE: VOLGENDE VRIJE CTID ##########

get_next_ctid() {
    local existing_vm existing_lxc all_ids max_id

    if command -v qm >/dev/null 2>&1; then
        existing_vm=$(qm list 2>/dev/null | awk 'NR>1 {print $1}')
    else
        existing_vm=""
    fi

    existing_lxc=$(pct list 2>/dev/null | awk 'NR>1 {print $1}')

    all_ids=$(printf "%s\n%s\n" "$existing_vm" "$existing_lxc" | awk 'NF' | sort -n | uniq)
    max_id=$(echo "$all_ids" | awk 'NF' | sort -n | tail -n1)

    if [ -z "$max_id" ]; then
        echo 100
    else
        echo $((max_id + 1))
    fi
}

########## INTRO ##########

clear
echo -e "${GREEN}"
echo "========================================="
echo "   Photoview Proxmox LXC Setup Helper"
echo "========================================="
echo -e "${NC}"
echo "Dit script:"
echo "  - maakt of hergebruikt een Debian LXC"
echo "  - zet nesting/fuse/keyctl aan"
echo "  - installeert Docker + Docker Compose plugin"
echo "  - draait Photoview + MariaDB via docker-compose"
echo

########## INTERACTIEVE INSTELLINGEN ##########

DEFAULT_CTID=$(get_next_ctid)
CTID=$(ask_default "Container ID" "$DEFAULT_CTID")
HOSTNAME=$(ask_default "Container hostname" "photoview")
STORAGE=$(ask_default "Rootfs storage (bv. local-lvm, local-zfs)" "local-lvm")
DISK_SIZE=$(ask_default "Root disk grootte" "16G")
MEMORY=$(ask_default "RAM (MB)" "2048")
CORES=$(ask_default "CPU cores" "2")
BRIDGE=$(ask_default "Netwerk bridge" "vmbr0")
TEMPLATE=$(ask_default "Template (storage:vztmpl/bestand)" "local:vztmpl/debian-12-standard_12.2-1_amd64.tar.zst")
APP_DIR="/opt/photoview"

echo
info "Samenvatting configuratie:"
echo "  CTID      : $CTID"
echo "  Hostname  : $HOSTNAME"
echo "  Storage   : $STORAGE"
echo "  Disk size : $DISK_SIZE"
echo "  Memory    : ${MEMORY}MB"
echo "  Cores     : $CORES"
echo "  Bridge    : $BRIDGE"
echo "  Template  : $TEMPLATE"
echo "  APP_DIR   : $APP_DIR (in de container)"
echo

read -rp "Doorgaan met deze instellingen? (y/N): " CONT
if [[ ! "$CONT" =~ ^[Yy]$ ]]; then
  warn "Afgebroken door gebruiker."
  exit 0
fi

########## HULPFUNCTIE: CT BESTAAT? ##########

ct_exists() {
  pct status "$CTID" &>/dev/null
}

########## CT AANMAKEN OF HERGEBRUIKEN ##########

if ct_exists; then
  warn "CT $CTID bestaat al, deze wordt hergebruikt."
else
  info "Container $CTID wordt aangemaakt..."

  pct create "$CTID" "$TEMPLATE" \
    --hostname "$HOSTNAME" \
    --storage "$STORAGE" \
    --rootfs "${STORAGE}:${DISK_SIZE}" \
    --memory "$MEMORY" \
    --cores "$CORES" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --features "nesting=1,fuse=1,keyctl=1" \
    --unprivileged 1 \
    --ostype debian

  ok "Container $CTID aangemaakt."
fi

########## CT STARTEN ##########

if pct status "$CTID" | grep -q "status: running"; then
  info "CT $CTID draait al."
else
  info "CT $CTID wordt gestart..."
  pct start "$CTID"
  sleep 5
fi

########## INSTALLER BINNEN DE CT ##########

info "Docker + Photoview minimal setup wordt binnen CT $CTID uitgevoerd..."

pct exec "$CTID" -- bash -s << 'EOF_CT'
set -e

APP_DIR="/opt/photoview"

echo "[CT] === APT update ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update

echo "[CT] === Docker check/install ==="
if command -v docker >/dev/null 2>&1; then
  echo "[CT] Docker is al geïnstalleerd:"
  docker --version
else
  echo "[CT] Docker wordt geïnstalleerd..."
  apt-get install -y curl ca-certificates gnupg
  curl -fsSL https://get.docker.com | sh
fi

echo "[CT] === Docker service check ==="
if systemctl is-active --quiet docker; then
  echo "[CT] Docker service draait."
else
  echo "[CT] Docker service wordt gestart..."
  systemctl start docker || true
fi

echo "[CT] === Docker Compose plugin check ==="
if docker compose version >/dev/null 2>&1; then
  echo "[CT] Docker Compose plugin is aanwezig."
else
  echo "[CT] Docker Compose plugin wordt geïnstalleerd..."
  apt-get install -y docker-compose-plugin
fi

echo "[CT] === Directories aanmaken ==="
mkdir -p "${APP_DIR}/photos"
mkdir -p "${APP_DIR}/cache"
cd "${APP_DIR}"

echo "[CT] === Minimal docker-compose.yml schrijven ==="
cat << 'EOF_DCY' > docker-compose.yml
version: "3"

services:
  db:
    image: mariadb:10.11
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: photoviewroot
      MYSQL_DATABASE: photoview
      MYSQL_USER: photoview
      MYSQL_PASSWORD: photoviewpass
    volumes:
      - db_data:/var/lib/mysql

  photoview:
    image: photoview/photoview:latest
    restart: always
    depends_on:
      - db
    ports:
      - "8080:80"
    environment:
      PHOTOVIEW_DATABASE_DRIVER: mysql
      PHOTOVIEW_MYSQL_URL: photoview:photoviewpass@tcp(db)/photoview
    volumes:
      - ./photos:/photos
      - ./cache:/app/cache

volumes:
  db_data:
EOF_DCY

echo "[CT] === Containers pullen en starten ==="
docker compose pull
docker compose up -d

echo "[CT] ======================================================"
echo "[CT] Photoview draait nu in deze container."
echo "[CT]  - docker-compose.yml : ${APP_DIR}/docker-compose.yml"
echo "[CT]  - Photos map         : ${APP_DIR}/photos"
echo "[CT]  - Cache map          : ${APP_DIR}/cache"
echo "[CT] ======================================================"
EOF_CT

########## AFSLUITEN / INFO ##########

CT_IP=$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}')

echo
ok "Setup voltooid!"

echo "---------------------------------------------"
echo " Photoview informatie:"
echo "  - Container ID : $CTID"
echo "  - Hostname     : $HOSTNAME"
if [ -n "$CT_IP" ]; then
  echo "  - IP adres     : $CT_IP"
  echo "  - URL          : http://$CT_IP:8080"
else
  echo "  - IP adres     : (kon niet automatisch bepaald worden)"
  echo "    Check in Proxmox GUI: CT $CTID → Summary → Network"
fi
echo
echo "  In de container kun je bv. doen:"
echo "    pct enter $CTID"
echo "    cd $APP_DIR"
echo "    docker compose ps"
echo "    docker compose logs -f photoview"
echo "---------------------------------------------"
echo
ok "Open de URL hierboven in je browser en maak je eerste Photoview gebruiker aan."
echo
