#!/usr/bin/env bash
set -u
set -o pipefail

export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

############################################
# KONFIG
############################################
LOGFILE="/var/log/showoff_installer.log"

# Komponensek (alapért. bekapcsolva)
ENABLE_APACHE=true
ENABLE_PHP=true
ENABLE_MARIADB=true
ENABLE_PHPMYADMIN=true
ENABLE_MOSQUITTO=true
ENABLE_SSH=true
ENABLE_UFW=true
ENABLE_NODE_RED=true

# Node-RED
NODE_RED_PORT=1880
NODE_RED_USERDIR="/var/lib/node-red"
NODE_LTS_MAJOR="20"   # 18 vagy 20 javasolt

# MariaDB
MARIADB_ROOT_PASSWORD=""   # ha üres, nem állítunk jelszót automatikusan

# UFW nyitások
UFW_ALLOW_SSH=true
UFW_ALLOW_HTTP=true
UFW_ALLOW_HTTPS=true
UFW_ALLOW_MQTT=true     # 1883
UFW_ALLOW_NODE_RED=true # 1880

############################################
# SZÍNEK / UI
############################################
RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; BLUE="\e[34m"
PURPLE="\e[35m"; CYAN="\e[36m"; BOLD="\e[1m"; NC="\e[0m"
GRAY="\e[90m"

############################################
# ÁLLAPOTOK (összegzéshez)
############################################
declare -A STATUS
declare -a ORDER
ORDER+=( "Apache" "PHP" "MariaDB" "phpMyAdmin" "Mosquitto" "SSH" "UFW" "Node-RED" )

set_status() { # set_status "Apache" "OK|SKIP|FAIL" "megjegyzés"
  local k="$1" v="$2" m="${3:-}"
  STATUS["$k"]="$v|$m"
}

############################################
# LOG / FUTTATÁS
############################################
mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true
touch "$LOGFILE" 2>/dev/null || true

log() { echo "[$(date '+%F %T')] $*" >> "$LOGFILE"; }

ok()   { echo -e "${GREEN}✔${NC} $*"; log "OK: $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; log "WARN: $*"; }
fail() { echo -e "${RED}✖${NC} $*"; log "FAIL: $*"; }

run() {
  log "RUN: $*"
  "$@" >> "$LOGFILE" 2>&1
}

############################################
# UI ELEMEK
############################################
banner() {
  clear
  echo -e "${CYAN}${BOLD}"
  cat << "EOF"
╔══════════════════════════════════════════════════════════════╗
║                 SHOW-OFF SERVER INSTALLER                   ║
║        Apache | Node-RED | MQTT | MariaDB | PHP | UFW        ║
║              Debian / Ubuntu  •  VirtualBox-safe             ║
╚══════════════════════════════════════════════════════════════╝
EOF
  echo -e "${NC}"
  echo -e "${BLUE}Logfile:${NC} $LOGFILE"
  echo
}

section() {
  local title="$1"
  echo -e "${PURPLE}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
  printf "${PURPLE}${BOLD}║${NC} ${CYAN}%-60s${NC} ${PURPLE}${BOLD}║${NC}\n" "$title"
  echo -e "${PURPLE}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
}

hr() { echo -e "${GRAY}────────────────────────────────────────────────────────────${NC}"; }

############################################
# ROOT CHECK
############################################
if [[ -z "${BASH_VERSION:-}" ]]; then
  echo "Ezt bash-al kell futtatni: bash ./install.sh"
  exit 1
fi

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Root jogosultság szükséges."
  echo "Futtasd így:"
  echo "  sudo bash ./install.sh"
  exit 1
fi

############################################
# APT WRAPPER
############################################
apt_update_once_done=false
apt_update_once() {
  if ! $apt_update_once_done; then
    section "APT frissítés"
    run apt-get update -y || return 1
    apt_update_once_done=true
  fi
}

apt_install() {
  apt_update_once || return 1
  run apt-get install -y --no-install-recommends "$@" || return 1
  return 0
}

############################################
# OS DETEKT
############################################
is_debian_like() { [[ -f /etc/debian_version ]]; }

############################################
# IGEN/NEM KÉRDÉS
############################################
ask_yn() { # ask_yn "Kérdés?" default(Y/N)
  local q="$1" def="${2:-Y}" ans=""
  local hint="Y/n"
  [[ "$def" == "N" ]] && hint="y/N"
  while true; do
    echo -ne "${CYAN}${q}${NC} (${hint}): "
    read -r ans || true
    ans="${ans:-$def}"
    case "$ans" in
      Y|y) return 0 ;;
      N|n) return 1 ;;
      *) echo "Kérlek Y vagy N." ;;
    esac
  done
}

############################################
# FELADAT FUTTATÓ
############################################
run_task() { # run_task "név" command...
  local name="$1"; shift
  echo -e "${BLUE}==>${NC} ${BOLD}${name}${NC}"
  if run "$@"; then
    ok "$name"
    return 0
  else
    fail "$name (részletek a logban)"
    return 1
  fi
}

############################################
# KÖZÖS: ports / gyors státusz
############################################
is_service_active() {
  local svc="$1"
  systemctl is-active --quiet "$svc" 2>/dev/null
}

############################################
# TELEPÍTŐK
############################################
install_apache() {
  section "Apache"
  if ! $ENABLE_APACHE; then
    set_status "Apache" "SKIP" "kikapcsolva"
    warn "Apache kihagyva (kikapcsolva)."
    return 0
  fi

  if dpkg -s apache2 >/dev/null 2>&1; then
    ok "Apache már telepítve."
  else
    apt_install apache2 || { set_status "Apache" "FAIL" "apt install"; return 1; }
  fi

  run systemctl enable --now apache2 || true
  if is_service_active apache2; then
    set_status "Apache" "OK" "fut"
    ok "Apache fut."
    return 0
  else
    set_status "Apache" "FAIL" "service nem aktív"
    warn "Apache nem aktív. (systemctl status apache2)"
    return 1
  fi
}

install_php() {
  section "PHP"
  if ! $ENABLE_PHP; then
    set_status "PHP" "SKIP" "kikapcsolva"
    warn "PHP kihagyva (kikapcsolva)."
    return 0
  fi

  local pkgs=(php php-cli php-fpm php-mysql php-xml php-mbstring php-curl php-zip libapache2-mod-php)
  local any_missing=false
  for p in "${pkgs[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || any_missing=true
  done

  if $any_missing; then
    apt_install "${pkgs[@]}" || { set_status "PHP" "FAIL" "apt install"; return 1; }
  else
    ok "PHP csomagok már telepítve."
  fi

  if [[ -d /var/www/html ]]; then
    cat > /var/www/html/info.php <<'EOF'
<?php
phpinfo();
EOF
    ok "info.php létrehozva: /var/www/html/info.php"
  fi

  run systemctl reload apache2 || true
  set_status "PHP" "OK" "telepítve"
  return 0
}

install_mariadb() {
  section "MariaDB"
  if ! $ENABLE_MARIADB; then
    set_status "MariaDB" "SKIP" "kikapcsolva"
    warn "MariaDB kihagyva (kikapcsolva)."
    return 0
  fi

  if dpkg -s mariadb-server >/dev/null 2>&1; then
    ok "MariaDB már telepítve."
  else
    apt_install mariadb-server || { set_status "MariaDB" "FAIL" "apt install"; return 1; }
  fi

  run systemctl enable --now mariadb || true

  if [[ -n "$MARIADB_ROOT_PASSWORD" ]]; then
    run mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${MARIADB_ROOT_PASSWORD}'; FLUSH PRIVILEGES;" || true
    ok "MariaDB root jelszó megkísérelve beállítani."
  fi

  if is_service_active mariadb; then
    set_status "MariaDB" "OK" "fut"
    ok "MariaDB fut."
    return 0
  else
    set_status "MariaDB" "FAIL" "service nem aktív"
    warn "MariaDB nem aktív."
    return 1
  fi
}

install_phpmyadmin() {
  section "phpMyAdmin"
  if ! $ENABLE_PHPMYADMIN; then
    set_status "phpMyAdmin" "SKIP" "kikapcsolva"
    warn "phpMyAdmin kihagyva (kikapcsolva)."
    return 0
  fi

  if dpkg -s phpmyadmin >/dev/null 2>&1; then
    ok "phpMyAdmin már telepítve."
    set_status "phpMyAdmin" "OK" "telepítve"
    return 0
  fi

  apt_update_once || { set_status "phpMyAdmin" "FAIL" "apt update"; return 1; }

  echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2" | run debconf-set-selections || true
  echo "phpmyadmin phpmyadmin/dbconfig-install boolean true" | run debconf-set-selections || true

  if apt_install phpmyadmin; then
    run phpenmod mbstring >/dev/null 2>&1 || true
    run systemctl reload apache2 || true
    ok "phpMyAdmin telepítve. Elérés: /phpmyadmin"
    set_status "phpMyAdmin" "OK" "telepítve"
    return 0
  else
    warn "phpMyAdmin telepítés sikertelen (gyakran debconf miatt)."
    set_status "phpMyAdmin" "FAIL" "apt install"
    return 1
  fi
}

install_mosquitto() {
  section "Mosquitto MQTT"
  if ! $ENABLE_MOSQUITTO; then
    set_status "Mosquitto" "SKIP" "kikapcsolva"
    warn "Mosquitto kihagyva (kikapcsolva)."
    return 0
  fi

  if dpkg -s mosquitto >/dev/null 2>&1; then
    ok "Mosquitto már telepítve."
  else
    apt_install mosquitto mosquitto-clients || { set_status "Mosquitto" "FAIL" "apt install"; return 1; }
  fi

  run systemctl enable --now mosquitto || true
  if is_service_active mosquitto; then
    set_status "Mosquitto" "OK" "fut"
    ok "Mosquitto fut (1883)."
    return 0
  else
    set_status "Mosquitto" "FAIL" "service nem aktív"
    warn "Mosquitto nem aktív."
    return 1
  fi
}

install_ssh() {
  section "SSH"
  if ! $ENABLE_SSH; then
    set_status "SSH" "SKIP" "kikapcsolva"
    warn "SSH kihagyva (kikapcsolva)."
    return 0
  fi

  if dpkg -s openssh-server >/dev/null 2>&1; then
    ok "OpenSSH Server már telepítve."
  else
    apt_install openssh-server || { set_status "SSH" "FAIL" "apt install"; return 1; }
  fi

  run systemctl enable --now ssh || run systemctl enable --now sshd || true
  if is_service_active ssh || is_service_active sshd; then
    set_status "SSH" "OK" "fut"
    ok "SSH fut."
    return 0
  else
    set_status "SSH" "FAIL" "service nem aktív"
    warn "SSH nem aktív."
    return 1
  fi
}

install_ufw() {
  section "UFW tűzfal"
  if ! $ENABLE_UFW; then
    set_status "UFW" "SKIP" "kikapcsolva"
    warn "UFW kihagyva (kikapcsolva)."
    return 0
  fi

  if dpkg -s ufw >/dev/null 2>&1; then
    ok "UFW már telepítve."
  else
    apt_install ufw || { set_status "UFW" "FAIL" "apt install"; return 1; }
  fi

  run ufw --force reset || true
  run ufw default deny incoming || true
  run ufw default allow outgoing || true

  $UFW_ALLOW_SSH       && run ufw allow OpenSSH >/dev/null 2>&1 || true
  $UFW_ALLOW_HTTP      && run ufw allow 80/tcp >/dev/null 2>&1 || true
  $UFW_ALLOW_HTTPS     && run ufw allow 443/tcp >/dev/null 2>&1 || true
  $UFW_ALLOW_MQTT      && run ufw allow 1883/tcp >/dev/null 2>&1 || true
  $UFW_ALLOW_NODE_RED  && run ufw allow "${NODE_RED_PORT}/tcp" >/dev/null 2>&1 || true

  # Debianon néha false-negative az "active" ellenőrzés, ezért:
  run systemctl enable --now ufw >/dev/null 2>&1 || true
  run ufw --force enable || true
  run sleep 1 || true

  if ufw status 2>/dev/null | grep -qi "active"; then
    set_status "UFW" "OK" "aktív"
    ok "UFW aktív."
    return 0
  else
    # Nem állítjuk FAIL-re automatikusan, mert gyakran csak UI/VM issue.
    warn "UFW státusz nem egyértelmű (lehet false-negative). Ellenőrzés: ufw status verbose"
    set_status "UFW" "FAIL" "nem aktív (vagy false-negative)"
    return 1
  fi
}

install_nodejs_lts_nodesource() {
  # Node.js LTS NodeSource-ból (apt repo helyett) – Node-RED miatt kritikus.
  section "Node.js LTS (NodeSource)"

  # Ha már van node, nézzük a verziót: Node-RED 3.x-hez javasolt >= 18
  if command -v node >/dev/null 2>&1; then
    local v
    v="$(node -v 2>/dev/null || true)"
    ok "Node már telepítve: ${v}"
    return 0
  fi

  apt_install curl ca-certificates gnupg || return 1

  # setup script
  if ! run bash -c "curl -fsSL https://deb.nodesource.com/setup_${NODE_LTS_MAJOR}.x | bash -"; then
    return 1
  fi

  apt_install nodejs || return 1

  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    ok "Node.js telepítve: $(node -v) | npm: $(npm -v)"
    return 0
  fi

  return 1
}

install_node_red() {
  section "Node-RED"
  if ! $ENABLE_NODE_RED; then
    set_status "Node-RED" "SKIP" "kikapcsolva"
    warn "Node-RED kihagyva (kikapcsolva)."
    return 0
  fi

  # Node.js LTS (NodeSource)
  if ! install_nodejs_lts_nodesource; then
    set_status "Node-RED" "FAIL" "nodejs/npm"
    fail "Node.js / npm telepítés sikertelen."
    return 1
  fi

  # Node-RED telepítés
  if ! command -v node-red >/dev/null 2>&1; then
    run_task "Node-RED (npm install -g)" npm install -g --unsafe-perm --no-audit --no-fund node-red \
      || { set_status "Node-RED" "FAIL" "npm install"; return 1; }
  else
    ok "Node-RED parancs már elérhető."
  fi

  # Abszolút bináris útvonal (systemd miatt kritikus)
  local NODE_RED_BIN
  NODE_RED_BIN="$(command -v node-red || true)"
  if [[ -z "$NODE_RED_BIN" ]]; then
    set_status "Node-RED" "FAIL" "bináris hiány"
    fail "Node-RED bináris nem található (command -v node-red üres)."
    return 1
  fi
  ok "Node-RED bináris: $NODE_RED_BIN"

  # Dedikált user + userDir
  id -u nodered >/dev/null 2>&1 || run useradd -r -m -s /usr/sbin/nologin nodered || true
  run mkdir -p "$NODE_RED_USERDIR" || true
  run chown -R nodered:nodered "$NODE_RED_USERDIR" || true

  # Systemd unit
  cat > /etc/systemd/system/nodered.service <<UNIT
[Unit]
Description=Node-RED
After=network.target

[Service]
Type=simple
User=nodered
Group=nodered
WorkingDirectory=${NODE_RED_USERDIR}

# npm -g gyakran /usr/local/bin-be telepít, ezt systemd alatt külön meg kell adni
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="NODE_RED_OPTIONS=--userDir ${NODE_RED_USERDIR} --port ${NODE_RED_PORT}"

ExecStart=${NODE_RED_BIN} \$NODE_RED_OPTIONS
Restart=on-failure
RestartSec=5
KillSignal=SIGINT
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target
UNIT

  run systemctl daemon-reload || true
  run systemctl enable --now nodered.service || true

  if is_service_active nodered.service; then
    set_status "Node-RED" "OK" "fut"
    ok "Node-RED fut (port: ${NODE_RED_PORT})."
    return 0
  fi

  warn "Node-RED nem indult el. Journal részlet:"
  run journalctl -u nodered.service --no-pager -n 160 || true
  set_status "Node-RED" "FAIL" "service nem aktív"
  return 1
}

############################################
# ÖSSZEGZÉS
############################################
print_summary() {
  section "Állapot összegzés"
  printf "%-14s | %-5s | %s\n" "Komponens" "Áll." "Megjegyzés"
  echo "---------------+-------+------------------------------------------"
  local k v state msg
  for k in "${ORDER[@]}"; do
    v="${STATUS[$k]:-SKIP|n/a}"
    state="${v%%|*}"
    msg="${v#*|}"
    printf "%-14s | %-5s | %s\n" "$k" "$state" "$msg"
  done
  echo
}

############################################
# INTERAKTÍV VÁLASZTÁS
############################################
configure_toggles() {
  section "Komponensek kiválasztása"
  ask_yn "Apache telepítése?" "Y" && ENABLE_APACHE=true || ENABLE_APACHE=false
  ask_yn "PHP telepítése?" "Y" && ENABLE_PHP=true || ENABLE_PHP=false
  ask_yn "MariaDB telepítése?" "Y" && ENABLE_MARIADB=true || ENABLE_MARIADB=false
  ask_yn "phpMyAdmin telepítése?" "Y" && ENABLE_PHPMYADMIN=true || ENABLE_PHPMYADMIN=false
  ask_yn "Mosquitto MQTT telepítése?" "Y" && ENABLE_MOSQUITTO=true || ENABLE_MOSQUITTO=false
  ask_yn "SSH telepítése?" "Y" && ENABLE_SSH=true || ENABLE_SSH=false
  ask_yn "UFW tűzfal konfigurálása?" "Y" && ENABLE_UFW=true || ENABLE_UFW=false
  ask_yn "Node-RED telepítése?" "Y" && ENABLE_NODE_RED=true || ENABLE_NODE_RED=false
  echo
}

############################################
# FŐ FUTÁS
############################################
main() {
  banner

  if ! is_debian_like; then
    warn "Ez a script Debian/Ubuntu alapra készült. Lehet, hogy nem fog működni."
  fi

  if ask_yn "Szeretnéd kiválasztani, mit telepítsünk (interaktív mód)?" "Y"; then
    configure_toggles
  fi

  hr
  ok "Telepítés indul."
  hr

  local all_ok=true

  install_apache     || all_ok=false
  install_php        || all_ok=false
  install_mariadb    || all_ok=false
  install_phpmyadmin || all_ok=false
  install_mosquitto  || all_ok=false
  install_ssh        || all_ok=false
  install_node_red   || all_ok=false
  install_ufw        || all_ok=false

  print_summary

  if $all_ok; then
    section "Befejezés"
    echo -e "${GREEN}${BOLD}KÉSZ – minden lépés sikeres.${NC}"
    echo -e "${PURPLE}»${NC} Apache:      http://<szerver-ip>/"
    echo -e "${PURPLE}»${NC} PHP info:     http://<szerver-ip>/info.php (ha telepítve)"
    echo -e "${PURPLE}»${NC} phpMyAdmin:   http://<szerver-ip>/phpmyadmin (ha telepítve)"
    echo -e "${PURPLE}»${NC} Node-RED:     http://<szerver-ip>:${NODE_RED_PORT}/ (ha telepítve)"
    echo -e "${PURPLE}»${NC} MQTT:         tcp/<szerver-ip>:1883 (ha telepítve)"
    echo
    exit 0
  else
    section "Befejezés"
    echo -e "${YELLOW}${BOLD}KÉSZ – volt sikertelen lépés.${NC}"
    echo -e "${YELLOW}Nézd a logot:${NC} $LOGFILE"
    echo
    exit 1
  fi
}

main "$@"
