#!/bin/bash
# Show-Off Server Installer (UI edition) – FIXED for set -u + spinner background
# Alap telepítési logika változatlan: Apache2, SSH, Mosquitto(+clients), Node-RED, MariaDB, PHP, UFW

set -u
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
: "${LOGFILE:=/var/log/showoff_installer.log}"

### ====== SZÍNEK ======
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
PURPLE="\e[35m"
CYAN="\e[36m"
BOLD="\e[1m"
DIM="\e[2m"
NC="\e[0m"

### ====== UI HELPEREK (csak megjelenítés) ======
term_cols() { tput cols 2>/dev/null || echo 80; }
hr() { printf '%*s\n' "$(term_cols)" '' | tr ' ' '═'; }

center() {
  local s="$1"
  local w
  w="$(term_cols)"
  local pad=$(( (w - ${#s}) / 2 ))
  (( pad < 0 )) && pad=0
  printf "%*s%s\n" "$pad" "" "$s"
}

spinner() {
  # spinner <pid> <text>
  local pid="$1"
  local text="$2"
  local spin='|/-\'
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    i=$(( (i + 1) % 4 ))
    printf "\r${CYAN}${spin:$i:1}${NC} %s" "$text"
    sleep 0.1
  done
  printf "\r%s\r" " "
}

panel() {
  # panel <color> <title> <line1> <line2> ...
  local color="$1"; shift
  local title="$1"; shift
  echo -e "${color}$(hr)${NC}"
  echo -e "${color}${BOLD}${title}${NC}"
  while [[ $# -gt 0 ]]; do
    echo -e "${color}•${NC} $1"
    shift
  done
  echo -e "${color}$(hr)${NC}"
}

### ====== ROOT CHECK ======
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo -e "${RED}Root jogosultság szükséges.${NC}"
  echo "Futtasd így:"
  echo "  su -"
  echo "  ./install.sh"
  exit 1
fi

### ====== LOG ======
mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true
touch "$LOGFILE" 2>/dev/null || true

log() { echo "$(date '+%F %T') | $1" | tee -a "$LOGFILE" >/dev/null; }
ok() { echo -e "${GREEN}✔ $1${NC}"; log "OK: $1"; }
warn() { echo -e "${YELLOW}⚠ $1${NC}"; log "WARN: $1"; }
fail() { echo -e "${RED}✖ $1${NC}"; log "FAIL: $1"; }

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    warn "[DRY-RUN] $*"
    return 0
  fi
  "$@"
}

### ====== BANNER ======
clear
echo -e "${PURPLE}${BOLD}"
center "╔══════════════════════════════════════════════════════╗"
center "║              SHOW-OFF SERVER INSTALLER               ║"
center "║  Apache | Node-RED | MQTT | MariaDB | PHP | UFW       ║"
center "║         VirtualBox / Debian / Ubuntu - ROBUSZTUS      ║"
center "╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "${BLUE}Logfile:${NC} $LOGFILE"
echo -e "${DIM}DRY_RUN=${DRY_RUN} | APACHE=${INSTALL_APACHE} SSH=${INSTALL_SSH} NR=${INSTALL_NODE_RED} MQTT=${INSTALL_MOSQUITTO} DB=${INSTALL_MARIADB} PHP=${INSTALL_PHP} UFW=${INSTALL_UFW}${NC}"
echo

### ====== EREDMÉNYEK ======
declare -A RESULTS
set_result() { RESULTS["$1"]="$2"; }

### ====== APT HELPERS ======
apt_update() {
  log "APT csomaglista frissítése"
  run apt-get update -y
}

apt_install() {
  log "Csomag telepítés: $*"
  run apt-get install -y "$@"
}

### ====== TELEPÍTŐK (alap logika változatlan) ======
install_apache() {
  apt_install apache2 || return 1
  run systemctl enable --now apache2 || return 1
  return 0
}

install_ssh() {
  apt_install openssh-server || return 1
  run systemctl enable --now ssh || return 1
  return 0
}

install_mosquitto() {
  apt_install mosquitto mosquitto-clients || return 1
  run systemctl enable --now mosquitto || return 1
  return 0
}

install_mariadb() {
  apt_install mariadb-server || return 1
  run systemctl enable --now mariadb || return 1
  return 0
}

install_php() {
  apt_install php libapache2-mod-php php-mysql || return 1
  run systemctl restart apache2 || return 1
  return 0
}

install_ufw() {
  apt_install ufw || return 1
  run ufw allow OpenSSH || return 1
  run ufw allow 80/tcp || return 1
  run ufw allow 1880/tcp || return 1
  run ufw allow 1883/tcp || return 1
  run ufw --force enable || return 1
  return 0
}

install_node_red() {
  apt_install curl ca-certificates || return 1

  log "Node-RED telepítés (non-interactive --confirm-root)"
  set +e
  curl -fsSL https://github.com/node-red/linux-installers/releases/latest/download/update-nodejs-and-nodered-deb \
    | bash -s -- --confirm-root
  local rc=$?
  set -e
  log "Node-RED installer exit code: $rc"

  run systemctl daemon-reload || true
  if systemctl list-unit-files | grep -q '^nodered\.service'; then
    run systemctl enable --now nodered.service || true
  fi

  systemctl is-active --quiet nodered 2>/dev/null
}

### ====== APT UPDATE show-off ======
panel "${CYAN}" "Előkészítés" "APT update fut..."
( apt_update ) & pid=$!
spinner "$pid" "APT update..."
wait "$pid"
rc=$?
if [[ $rc -eq 0 ]]; then
  ok "APT update kész"
else
  fail "APT update sikertelen (internet/DNS/repo gond)."
  exit 1
fi
echo

### ====== RUN INSTALL (FIXED) ======
# FIX: nem a subshell állítja a RESULTS-t, hanem a fő folyamat a wait exit code alapján.
run_install() {
  local var="$1"
  local label="$2"
  local func="$3"

  echo -e "${BLUE}${BOLD}==> ${label}${NC}"

  if [[ "${!var:-false}" == "true" ]]; then
    # Futassuk a telepítést backgroundban a spinner miatt,
    # majd a wait exit code alapján állítsuk a RESULTS-t ITT (parentben).
    ( "$func" ) & pid=$!
    spinner "$pid" "Telepítés: $label"
    wait "$pid"
    local step_rc=$?

    if [[ $step_rc -eq 0 ]]; then
      set_result "$label" "SIKERES"
      ok "$label OK"
    else
      set_result "$label" "HIBA"
      fail "$label HIBA"
      # Ha azt akarod, hogy hiba esetén is menjen tovább, ezt a sort kommentezd ki:
      # return 0
      return 1
    fi
  else
    set_result "$label" "KIHAGYVA"
    warn "$label kihagyva (config: $var=false)"
  fi
  echo
}

run_install INSTALL_APACHE     "Apache2"   install_apache
run_install INSTALL_SSH        "SSH"       install_ssh
run_install INSTALL_MOSQUITTO  "Mosquitto" install_mosquitto
run_install INSTALL_NODE_RED   "Node-RED"  install_node_red
run_install INSTALL_MARIADB    "MariaDB"   install_mariadb
run_install INSTALL_PHP        "PHP"       install_php
run_install INSTALL_UFW        "UFW"       install_ufw

### ====== HEALTH CHECK + PORT CHECK ======
panel "${CYAN}" "HEALTH CHECK" "Szolgáltatások állapota"
for svc in apache2 ssh mosquitto mariadb nodered; do
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    ok "$svc RUNNING"
  else
    warn "$svc NEM FUT"
  fi
done
echo

panel "${CYAN}" "PORT CHECK" "Ellenőrzés: 80 / 1880 / 1883"
if command -v ss >/dev/null 2>&1; then
  if ss -tulpn | grep -E '(:80|:1880|:1883)\b' >/dev/null; then
    ok "Portok rendben"
  else
    warn "Nem látok hallgatózó portot (lehet szolgáltatás nem fut)."
  fi
else
  warn "ss parancs nem elérhető"
fi
echo

### ====== DASHBOARD ======
echo -e "${BOLD}=================================${NC}"
echo -e "${BOLD}  TELEPÍTÉSI DASHBOARD${NC}"
echo -e "${BOLD}=================================${NC}"

any_fail=0
for k in "${!RESULTS[@]}"; do
  case "${RESULTS[$k]}" in
    SIKERES) echo -e "${GREEN}✔${NC} $k : ${GREEN}${RESULTS[$k]}${NC}" ;;
    KIHAGYVA) echo -e "${YELLOW}⏭${NC} $k : ${YELLOW}${RESULTS[$k]}${NC}" ;;
    *) echo -e "${RED}✖${NC} $k : ${RED}${RESULTS[$k]}${NC}"; any_fail=1 ;;
  esac
done
echo

if [[ "$any_fail" -eq 0 ]]; then
  echo -e "${GREEN}KÉSZ – minden lépés rendben lefutott.${NC}"
  log "Telepítés befejezve: SIKERES"

  echo
  echo -e "${PURPLE}"
  cat << "EOF"
██╗  ██╗ █████╗      ██╗██████╗  █████╗     ██╗     ██╗██╗      █████╗ ██╗  ██╗
██║  ██║██╔══██╗     ██║██╔══██╗██╔══██╗    ██║     ██║██║     ██╔══██╗██║ ██╔╝
███████║███████║     ██║██████╔╝███████║    ██║     ██║██║     ███████║█████╔╝ 
██╔══██║██╔══██║██   ██║██╔══██╗██╔══██║    ██║     ██║██║     ██╔══██║██╔═██╗ 
██║  ██║██║  ██║╚█████╔╝██║  ██║██║  ██║    ███████╗██║███████╗██║  ██║██║  ██╗
╚═╝  ╚═╝╚═╝  ╚═╝ ╚════╝ ╚═╝  ╚═╝╚═╝  ╚═╝    ╚══════╝╚═╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝
EOF
  echo -e "${NC}"
  echo -e "${PURPLE}(Stahl Dávid Jenő)${NC}"
  exit 0
else
  warn "KÉSZ – volt sikertelen lépés. Nézd a logot: $LOGFILE"
  log "Telepítés befejezve: RÉSZBEN SIKERES"
  exit 1
fi
