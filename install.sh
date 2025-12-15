#!/bin/bash
set -Eeuo pipefail

### ====== VIRTUALBOX / MINIMAL FIXEK ======
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export DEBIAN_FRONTEND=noninteractive

### ====== KONFIG ======
CONFIG_FILE="./config.conf"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
else
  echo "WARN: config.conf nem található, alapértelmezett értékekkel futok."
fi

: "${DRY_RUN:=false}"
: "${INSTALL_APACHE:=true}"
: "${INSTALL_SSH:=true}"
: "${INSTALL_NODE_RED:=true}"
: "${INSTALL_MOSQUITTO:=true}"
: "${INSTALL_MARIADB:=true}"
: "${INSTALL_PHP:=true}"
: "${INSTALL_UFW:=true}"

LOGFILE="${LOGFILE:-/var/log/showoff_installer.log}"

### ====== SZÍNEK ======
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
NC="\e[0m"

### ====== ROOT CHECK ======
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo -e "${RED}Root jogosultság szükséges. Futtasd így: su - majd ./install.sh${NC}"
  exit 1
fi

### ====== LOG ELŐKÉSZÍTÉS ======
# Biztosítsuk, hogy a log könyvtár létezik
mkdir -p "$(dirname "$LOGFILE")"
touch "$LOGFILE" || {
  echo -e "${RED}Nem tudom létrehozni a logot: $LOGFILE${NC}"
  exit 1
}

log() {
  echo "$(date '+%F %T') | $1" | tee -a "$LOGFILE" >/dev/null
}

ok() {
  echo -e "${GREEN}✔ $1${NC}"
  log "OK: $1"
}

warn() {
  echo -e "${YELLOW}⚠ $1${NC}"
  log "WARN: $1"
}

fail() {
  echo -e "${RED}✖ $1${NC}"
  log "FAIL: $1"
  exit 1
}

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    warn "[DRY-RUN] $*"
    return 0
  fi
  "$@"
}

trap 'fail "A script váratlanul megszakadt (sor: ${BASH_LINENO[0]}). Nézd a logot: '"$LOGFILE"'"' ERR

### ====== BANNER ======
clear
cat << "EOF"
=========================================
  SHOW-OFF SERVER INSTALLER v1.2
  Apache | Node-RED | MQTT | MariaDB | UFW
  VirtualBox / Debian / Ubuntu kompatibilis
=========================================
EOF
echo -e "${BLUE}Logfile:${NC} $LOGFILE"
echo

### ====== APT UPDATE (STABIL) ======
apt_update() {
  log "APT csomaglista frissítése"
  run apt-get update -y
}

apt_install() {
  # használj apt-get-et, scriptből stabilabb
  log "Csomag telepítés: $*"
  run apt-get install -y "$@"
}

### ====== INSTALL FUNCS ======
install_apache() {
  log "Apache2 telepítés"
  apt_install apache2
  run systemctl enable --now apache2
  ok "Apache2 fut"
}

install_ssh() {
  log "OpenSSH telepítés"
  apt_install openssh-server
  run systemctl enable --now ssh
  ok "OpenSSH aktív"
}

install_node_red() {
  log "curl telepítés"
  apt_install curl ca-certificates

  log "Node-RED telepítés (non-interactive, root confirm)"
  # --confirm-root: ne álljon meg Enter kérdésnél
  run bash -c "curl -fsSL https://github.com/node-red/linux-installers/releases/latest/download/update-nodejs-and-nodered-deb | bash -s -- --confirm-root"

  # szolgáltatás indítása/engedélyezése
  run systemctl daemon-reload || true
  run systemctl enable --now nodered.service
  ok "Node-RED telepítve"
}

install_mosquitto() {
  log "Mosquitto MQTT telepítés"
  apt_install mosquitto mosquitto-clients
  run systemctl enable --now mosquitto
  ok "Mosquitto fut"
}

install_mariadb() {
  log "MariaDB telepítés"
  apt_install mariadb-server
  run systemctl enable --now mariadb
  ok "MariaDB fut"
}

install_php() {
  log "PHP + Apache modul telepítés"
  apt_install php libapache2-mod-php php-mysql
  run systemctl restart apache2
  ok "PHP Apache modul aktív"
}

install_ufw() {
  log "UFW tűzfal beállítás"
  apt_install ufw

  # Szabályok (kért portok)
  run ufw allow OpenSSH
  run ufw allow 80/tcp
  run ufw allow 1880/tcp
  run ufw allow 1883/tcp

  run ufw --force enable
  ok "UFW engedélyezve"
}

### ====== TELEPÍTÉSI LISTA ======
SERVICES=(
  INSTALL_APACHE:install_apache
  INSTALL_SSH:install_ssh
  INSTALL_NODE_RED:install_node_red
  INSTALL_MOSQUITTO:install_mosquitto
  INSTALL_MARIADB:install_mariadb
  INSTALL_PHP:install_php
  INSTALL_UFW:install_ufw
)

### ====== FUTTATÁS ======
apt_update

TOTAL=${#SERVICES[@]}
COUNT=0

for s in "${SERVICES[@]}"; do
  COUNT=$((COUNT+1))
  VAR="${s%%:*}"
  FUNC="${s##*:}"

  echo -e "${BLUE}[$COUNT/$TOTAL]${NC} $FUNC"

  # ha nincs beállítva a változó, tekintsük false-nak
  if [[ "${!VAR:-false}" == "true" ]]; then
    "$FUNC"
  else
    warn "$FUNC kihagyva (config: $VAR=false)"
  fi
done

### ====== HEALTH CHECK ======
echo
log "Szolgáltatások állapota"
for svc in apache2 ssh mosquitto mariadb nodered; do
  if systemctl is-active --quiet "$svc"; then
    ok "$svc RUNNING"
  else
    warn "$svc NEM FUT"
  fi
done

### ====== PORT CHECK (HASZNOS VBOX-BAN) ======
echo
log "Port ellenőrzés (80, 1880, 1883)"
if command -v ss >/dev/null 2>&1; then
  ss -tulpn | grep -E '(:80|:1880|:1883)\b' || warn "Nem látok hallgatózó portot (lehet még indul, vagy szolgáltatás nem fut)."
else
  warn "ss parancs nem elérhető"
fi

### ====== SUMMARY ======
echo -e "${GREEN}
=================================
  TELEPÍTÉS BEFEJEZVE ✔
=================================
${NC}"

log "Telepítés befejezve"
