#!/usr/bin/env bash
set -u
set -o pipefail

export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

############################################
# KONFIG
############################################
LOGFILE="/var/log/showoff_installer.log"

# ZENE (YouTube) – a kért linkkel
YOUTUBE_URL="https://www.youtube.com/watch?v=jj0ChLVTpaA&list=RDjj0ChLVTpaA&start_radio=1"
MUSIC_VOLUME=70
ENABLE_MUSIC=false
MUSIC_PID=""

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

# APT update kérdés (runtime állítja)
DO_APT_UPDATE=true

############################################
# SZÍNEK / UI
############################################
RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; BLUE="\e[34m"
PURPLE="\e[35m"; CYAN="\e[36m"; BOLD="\e[1m"; NC="\e[0m"
GRAY="\e[90m"; WHITE="\e[97m"

############################################
# ÁLLAPOTOK (összegzéshez)
############################################
declare -A STATUS
declare -a ORDER
ORDER+=( "Apache" "PHP" "MariaDB" "phpMyAdmin" "Mosquitto" "SSH" "UFW" "Node-RED" )

# Akciók (default: install – így a működés alapból nem változik)
ACTION_APACHE="install"
ACTION_PHP="install"
ACTION_MARIADB="install"
ACTION_PHPMYADMIN="install"
ACTION_MOSQUITTO="install"
ACTION_SSH="install"
ACTION_UFW="install"
ACTION_NODE_RED="install"

set_status() { # set_status "Apache" "OK|SKIP|FAIL|REM" "megjegyzés"
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
info() { echo -e "${CYAN}i${NC} $*"; log "INFO: $*"; }

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
  printf "${PURPLE}${BOLD}║${NC} ${WHITE}%-60s${NC} ${PURPLE}${BOLD}║${NC}\n" "$title"
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
# INPUT FIX (CTRL+C bug megszüntetése)
# - promptok stderr-re mennek (nem nyeli el a $(...) )
# - ha nincs TTY (pl. pipe/cron), automatikusan defaultol
############################################
has_tty() {
  [[ -t 0 ]] || [[ -t 1 ]] || [[ -t 2 ]]
}

read_line_or_default() { # $1=default -> echo answer
  local def="$1" ans=""
  if [[ -t 0 ]]; then
    IFS= read -r ans || ans=""
    ans="${ans:-$def}"
    echo "$ans"
    return 0
  fi
  # nincs interaktív stdin -> default (nem blokkolunk)
  echo "$def"
}

ask_yn() { # ask_yn "Kérdés?" default(Y/N)
  local q="$1" def="${2:-Y}" ans=""
  local hint="Y/n"
  [[ "$def" == "N" ]] && hint="y/N"
  while true; do
    printf "%b%s%b (%s): " "$CYAN" "$q" "$NC" "$hint" >&2
    ans="$(read_line_or_default "$def")"
    case "$ans" in
      Y|y) return 0 ;;
      N|n) return 1 ;;
      *) printf "Kérlek Y vagy N.\n" >&2 ;;
    esac
  done
}

ask_action() { # ask_action "Apache" default(I/R/S) -> stdout: install/remove/skip
  local name="$1"
  local def="${2:-I}"
  local ans=""
  local hint="I=Telepít / R=Töröl / S=Kihagy"
  while true; do
    printf "%b%s:%b %s (alap: %s): " "$CYAN" "$name" "$NC" "$hint" "$def" >&2
    ans="$(read_line_or_default "$def")"
    case "$ans" in
      I|i) echo "install"; return 0 ;;
      R|r) echo "remove";  return 0 ;;
      S|s) echo "skip";    return 0 ;;
      *)   printf "Kérlek I / R / S.\n" >&2 ;;
    esac
  done
}

############################################
# APT WRAPPER
############################################
apt_update_once_done=false
apt_update_once() {
  if $apt_update_once_done; then
    return 0
  fi
  if ! $DO_APT_UPDATE; then
    info "APT update kihagyva (felhasználói döntés)."
    apt_update_once_done=true
    return 0
  fi
  section "APT frissítés"
  run apt-get update -y || return 1
  apt_update_once_done=true
}

apt_install() {
  apt_update_once || return 1
  run apt-get install -y --no-install-recommends "$@" || return 1
  return 0
}

apt_purge() {
  apt_update_once || true
  run apt-get purge -y "$@" || return 1
  run apt-get autoremove -y || true
  return 0
}

############################################
# ZENE (YouTube stream) – START/STOP (JAVÍTOTT + yt-dlp frissítés fallback)
############################################
get_stream_url() {
  # 1) sima
  timeout 25 yt-dlp --no-playlist -f bestaudio --get-url "$YOUTUBE_URL" 2>>"$LOGFILE" | head -n 1
}

get_stream_url_android() {
  # 2) android kliens (gyakran megoldja az extract hibát)
  timeout 25 yt-dlp --no-playlist -f bestaudio --get-url \
    --extractor-args "youtube:player_client=android" \
    "$YOUTUBE_URL" 2>>"$LOGFILE" | head -n 1
}

start_music() {
  $ENABLE_MUSIC || return 0

  section "Zene"

  # kellékek
  if ! command -v yt-dlp >/dev/null 2>&1; then
    info "Zene: yt-dlp telepítése..."
    apt_install yt-dlp || { warn "Zene: yt-dlp telepítése nem sikerült."; return 0; }
  fi
  if ! command -v mpv >/dev/null 2>&1; then
    info "Zene: mpv telepítése..."
    apt_install mpv || { warn "Zene: mpv telepítése nem sikerült."; return 0; }
  fi

  # stream URL kinyerése – több lépéses fallback
  local stream_url=""
  stream_url="$(get_stream_url || true)"
  if [[ -z "$stream_url" ]]; then
    stream_url="$(get_stream_url_android || true)"
  fi

  # ha még mindig üres, frissítjük yt-dlp-t pip-pel és újrapróbáljuk
  if [[ -z "$stream_url" ]]; then
    warn "Zene: yt-dlp nem tudta kinyerni a stream URL-t. Megpróbálom frissíteni yt-dlp-t..."
    apt_install python3-pip python3-venv >/dev/null 2>&1 || true
    # pip3 upgrade (rootként)
    timeout 120 pip3 install -U yt-dlp >>"$LOGFILE" 2>&1 || true

    # újra próbák
    stream_url="$(get_stream_url || true)"
    if [[ -z "$stream_url" ]]; then
      stream_url="$(get_stream_url_android || true)"
    fi
  fi

  if [[ -z "$stream_url" ]]; then
    warn "Zene: nem sikerült kinyerni a stream URL-t a YouTube linkből."
    return 0
  fi

  # lejátszás indítása háttérben
  mpv --no-video --quiet --volume="$MUSIC_VOLUME" "$stream_url" >>"$LOGFILE" 2>&1 &
  MUSIC_PID="$!"

  if [[ -n "${MUSIC_PID:-}" ]] && kill -0 "$MUSIC_PID" 2>/dev/null; then
    ok "Megy a zene."
  else
    warn "Zene: nem indult el a lejátszás."
    MUSIC_PID=""
  fi
}

stop_music() {
  if [[ -n "${MUSIC_PID:-}" ]]; then
    if kill -0 "$MUSIC_PID" 2>/dev/null; then
      kill "$MUSIC_PID" >/dev/null 2>&1 || true
      sleep 0.3 || true
      kill -9 "$MUSIC_PID" >/dev/null 2>&1 || true
    fi
    MUSIC_PID=""
    ok "Zene leállítva."
  fi
}

cleanup() {
  stop_music
}
trap cleanup EXIT INT TERM

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
# KÖZÖS: service check
############################################
is_service_active() {
  local svc="$1"
  systemctl is-active --quiet "$svc" 2>/dev/null
}

############################################
# TÖRLŐK (REMOVE)
############################################
remove_apache() {
  section "Apache – törlés"
  run systemctl disable --now apache2 >/dev/null 2>&1 || true
  if dpkg -s apache2 >/dev/null 2>&1; then
    apt_purge apache2 apache2-bin apache2-data apache2-utils || return 1
  fi
  set_status "Apache" "REM" "eltávolítva"
  ok "Apache eltávolítva."
}

remove_php() {
  section "PHP – törlés"
  local pkgs=(php php-cli php-fpm php-mysql php-xml php-mbstring php-curl php-zip libapache2-mod-php)
  apt_purge "${pkgs[@]}" >/dev/null 2>&1 || true
  run rm -f /var/www/html/info.php >/dev/null 2>&1 || true
  set_status "PHP" "REM" "eltávolítva"
  ok "PHP eltávolítva."
}

remove_mariadb() {
  section "MariaDB – törlés"
  run systemctl disable --now mariadb >/dev/null 2>&1 || true
  if dpkg -s mariadb-server >/dev/null 2>&1; then
    apt_purge mariadb-server mariadb-client >/dev/null 2>&1 || true
  fi
  warn "MariaDB adatkönyvtárat nem töröltem automatikusan (/var/lib/mysql)."
  set_status "MariaDB" "REM" "eltávolítva"
  ok "MariaDB eltávolítva."
}

remove_phpmyadmin() {
  section "phpMyAdmin – törlés"
  if dpkg -s phpmyadmin >/dev/null 2>&1; then
    apt_purge phpmyadmin >/dev/null 2>&1 || true
  fi
  set_status "phpMyAdmin" "REM" "eltávolítva"
  ok "phpMyAdmin eltávolítva."
}

remove_mosquitto() {
  section "Mosquitto – törlés"
  run systemctl disable --now mosquitto >/dev/null 2>&1 || true
  if dpkg -s mosquitto >/dev/null 2>&1; then
    apt_purge mosquitto mosquitto-clients >/dev/null 2>&1 || true
  fi
  set_status "Mosquitto" "REM" "eltávolítva"
  ok "Mosquitto eltávolítva."
}

remove_ssh() {
  section "SSH – törlés"
  warn "FIGYELEM: ha távolról vagy belépve, az SSH törlése kizárhat."
  if ! ask_yn "Biztosan törlöd az OpenSSH Servert?" "N"; then
    set_status "SSH" "SKIP" "törlés megszakítva"
    warn "SSH törlés megszakítva."
    return 0
  fi
  run systemctl disable --now ssh >/dev/null 2>&1 || true
  run systemctl disable --now sshd >/dev/null 2>&1 || true
  if dpkg -s openssh-server >/dev/null 2>&1; then
    apt_purge openssh-server >/dev/null 2>&1 || true
  fi
  set_status "SSH" "REM" "eltávolítva"
  ok "SSH eltávolítva."
}

remove_ufw() {
  section "UFW – törlés"
  run ufw --force disable >/dev/null 2>&1 || true
  run systemctl disable --now ufw >/dev/null 2>&1 || true
  if dpkg -s ufw >/dev/null 2>&1; then
    apt_purge ufw >/dev/null 2>&1 || true
  fi
  set_status "UFW" "REM" "eltávolítva"
  ok "UFW eltávolítva."
}

remove_node_red() {
  section "Node-RED – törlés"
  run systemctl disable --now nodered.service >/dev/null 2>&1 || true
  run rm -f /etc/systemd/system/nodered.service >/dev/null 2>&1 || true
  run systemctl daemon-reload >/dev/null 2>&1 || true

  if command -v npm >/dev/null 2>&1; then
    run_task "Node-RED (npm remove -g)" npm remove -g node-red || true
  fi

  if [[ -d "$NODE_RED_USERDIR" ]]; then
    if ask_yn "Töröljem a Node-RED userDir-t is? (${NODE_RED_USERDIR})" "N"; then
      run rm -rf "$NODE_RED_USERDIR" >/dev/null 2>&1 || true
      ok "Node-RED userDir törölve."
    else
      info "Node-RED userDir megmaradt: ${NODE_RED_USERDIR}"
    fi
  fi

  if id -u nodered >/dev/null 2>&1; then
    if ask_yn "Töröljem a 'nodered' felhasználót is?" "N"; then
      run userdel -r nodered >/dev/null 2>&1 || true
      ok "nodered user törölve."
    else
      info "nodered user megmaradt."
    fi
  fi

  set_status "Node-RED" "REM" "eltávolítva"
  ok "Node-RED eltávolítva."
}

############################################
# TELEPÍTŐK (INSTALL)
############################################
install_apache() {
  section "Apache – telepítés"
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
  section "PHP – telepítés"
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

  run systemctl reload apache2 >/dev/null 2>&1 || true
  set_status "PHP" "OK" "telepítve"
  return 0
}

install_mariadb() {
  section "MariaDB – telepítés"

  if ! dpkg -s mariadb-server >/dev/null 2>&1; then
    apt_install mariadb-server || {
      set_status "MariaDB" "FAIL" "apt install"
      return 1
    }
  else
    ok "MariaDB már telepítve."
  fi

  # --- KRITIKUS JAVÍTÁS BLOKK ---

  # 1) runtime dir
  run mkdir -p /run/mysqld || true
  run chown mysql:mysql /run/mysqld || true
  run chmod 755 /run/mysqld || true

  # 2) adatkönyvtár jogosultság
  if [[ -d /var/lib/mysql ]]; then
    run chown -R mysql:mysql /var/lib/mysql || true
    run chmod 750 /var/lib/mysql || true
  fi

  # 3) Aria / InnoDB crash cleanup
  run rm -f /var/lib/mysql/aria_log_control /var/lib/mysql/aria_log.* >/dev/null 2>&1 || true
  run rm -f /var/lib/mysql/ib_logfile* >/dev/null 2>&1 || true

  # 4) HA MÉG NINCS INITIALIZÁLVA → bootstrap
  if [[ ! -d /var/lib/mysql/mysql ]]; then
    warn "MariaDB adatbázis nem inicializált – bootstrap indul."
    run mariadb-install-db --user=mysql --basedir=/usr --datadir=/var/lib/mysql || {
      set_status "MariaDB" "FAIL" "init db"
      return 1
    }
  fi

  # 5) indulás
  run systemctl daemon-reexec || true
  run systemctl enable mariadb || true
  run systemctl restart mariadb || true

  # 6) ellenőrzés
  if is_service_active mariadb; then
    set_status "MariaDB" "OK" "fut"
    ok "MariaDB fut."
    return 0
  fi

  # ha ide jutunk: HARD FAIL → logoljuk
  warn "MariaDB továbbra sem aktív – részletek:"
  run systemctl status mariadb --no-pager -l || true
  run journalctl -u mariadb --no-pager -n 150 || true

  set_status "MariaDB" "FAIL" "service nem aktív"
  return 1
}



install_phpmyadmin() {
  section "phpMyAdmin – telepítés"
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
    run systemctl reload apache2 >/dev/null 2>&1 || true
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
  section "Mosquitto – telepítés"
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
  section "SSH – telepítés"
  if dpkg -s openssh-server >/dev/null 2>&1; then
    ok "OpenSSH Server már telepítve."
  else
    apt_install openssh-server || { set_status "SSH" "FAIL" "apt install"; return 1; }
  fi

  run systemctl enable --now ssh >/dev/null 2>&1 || run systemctl enable --now sshd >/dev/null 2>&1 || true
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
  section "UFW – telepítés"
  if dpkg -s ufw >/dev/null 2>&1; then
    ok "UFW már telepítve."
  else
    apt_install ufw || { set_status "UFW" "FAIL" "apt install"; return 1; }
  fi

  run ufw --force reset || true
  run ufw default deny incoming || true
  run ufw default allow outgoing || true

  $UFW_ALLOW_SSH      && run ufw allow OpenSSH >/dev/null 2>&1 || true
  $UFW_ALLOW_HTTP     && run ufw allow 80/tcp >/dev/null 2>&1 || true
  $UFW_ALLOW_HTTPS    && run ufw allow 443/tcp >/dev/null 2>&1 || true
  $UFW_ALLOW_MQTT     && run ufw allow 1883/tcp >/dev/null 2>&1 || true
  $UFW_ALLOW_NODE_RED && run ufw allow "${NODE_RED_PORT}/tcp" >/dev/null 2>&1 || true

  run systemctl enable --now ufw >/dev/null 2>&1 || true
  run ufw --force enable || true
  run sleep 1 || true

  if ufw status 2>/dev/null | grep -qi "active"; then
    set_status "UFW" "OK" "aktív"
    ok "UFW aktív."
    return 0
  else
    warn "UFW státusz nem egyértelmű (lehet false-negative). Ellenőrzés: ufw status verbose"
    set_status "UFW" "FAIL" "nem aktív (vagy false-negative)"
    return 1
  fi
}

install_nodejs_lts_nodesource() {
  section "Node.js LTS (NodeSource)"

  if command -v node >/dev/null 2>&1; then
    ok "Node már telepítve: $(node -v 2>/dev/null || true)"
    if command -v npm >/dev/null 2>&1; then
      ok "npm elérhető: $(npm -v 2>/dev/null || true)"
      return 0
    fi
  fi

  apt_install curl ca-certificates gnupg || return 1

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
  section "Node-RED – telepítés"

  if ! install_nodejs_lts_nodesource; then
    set_status "Node-RED" "FAIL" "nodejs/npm"
    fail "Node.js / npm telepítés sikertelen."
    return 1
  fi

  if ! command -v node-red >/dev/null 2>&1; then
    run_task "Node-RED (npm install -g)" npm install -g --unsafe-perm --no-audit --no-fund node-red \
      || { set_status "Node-RED" "FAIL" "npm install"; return 1; }
  else
    ok "Node-RED parancs már elérhető."
  fi

  local NODE_RED_BIN
  NODE_RED_BIN="$(command -v node-red || true)"
  if [[ -z "$NODE_RED_BIN" ]]; then
    set_status "Node-RED" "FAIL" "bináris hiány"
    fail "Node-RED bináris nem található (command -v node-red üres)."
    return 1
  fi
  ok "Node-RED bináris: $NODE_RED_BIN"

  id -u nodered >/dev/null 2>&1 || run useradd -r -m -s /usr/sbin/nologin nodered || true
  run mkdir -p "$NODE_RED_USERDIR" || true
  run chown -R nodered:nodered "$NODE_RED_USERDIR" || true

  cat > /etc/systemd/system/nodered.service <<UNIT
[Unit]
Description=Node-RED
After=network.target

[Service]
Type=simple
User=nodered
Group=nodered
WorkingDirectory=${NODE_RED_USERDIR}

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
# AKCIÓ DISPATCH
############################################
do_component() { # do_component "Apache" "$ACTION_APACHE" install_fn remove_fn
  local name="$1" action="$2" install_fn="$3" remove_fn="$4"
  case "$action" in
    install) "$install_fn" ;;
    remove)  "$remove_fn" ;;
    skip)
      set_status "$name" "SKIP" "kihagyva"
      warn "${name} kihagyva."
      ;;
    *)
      set_status "$name" "SKIP" "ismeretlen akció"
      warn "${name}: ismeretlen akció -> kihagyva."
      ;;
  esac
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
# INTERAKTÍV VÁLASZTÁS (ZENE + APT + I/R/S)
############################################
configure_actions() {
  section "Beállítások"

  if ask_yn "Menjen zene induláskor? (YouTube)" "N"; then
    ENABLE_MUSIC=true
  else
    ENABLE_MUSIC=false
  fi

  if ask_yn "Futtassunk APT update-et a telepítések előtt?" "Y"; then
    DO_APT_UPDATE=true
    ok "APT update: engedélyezve"
  else
    DO_APT_UPDATE=false
    warn "APT update: kihagyva (telepítésnél gond lehet, ha régi a csomaglista)"
  fi
  echo

  section "Komponensek – válassz műveletet"
  ACTION_APACHE="$(ask_action "Apache" "I")"
  ACTION_PHP="$(ask_action "PHP" "I")"
  ACTION_MARIADB="$(ask_action "MariaDB" "I")"
  ACTION_PHPMYADMIN="$(ask_action "phpMyAdmin" "I")"
  ACTION_MOSQUITTO="$(ask_action "Mosquitto" "I")"
  ACTION_SSH="$(ask_action "SSH" "I")"
  ACTION_NODE_RED="$(ask_action "Node-RED" "I")"
  ACTION_UFW="$(ask_action "UFW" "I")"
  echo
}

############################################
# FŐ FUTÁS
############################################
main() {
  banner
  configure_actions

  # Zene indítása (ha kérted)
  start_music

  hr
  ok "Műveletek indulnak."
  hr

  local all_ok=true

  do_component "Apache"     "$ACTION_APACHE"      install_apache      remove_apache      || all_ok=false
  do_component "PHP"        "$ACTION_PHP"         install_php         remove_php         || all_ok=false
  do_component "MariaDB"    "$ACTION_MARIADB"     install_mariadb     remove_mariadb     || all_ok=false
  do_component "phpMyAdmin" "$ACTION_PHPMYADMIN"  install_phpmyadmin  remove_phpmyadmin  || all_ok=false
  do_component "Mosquitto"  "$ACTION_MOSQUITTO"   install_mosquitto   remove_mosquitto   || all_ok=false
  do_component "SSH"        "$ACTION_SSH"         install_ssh         remove_ssh         || all_ok=false
  do_component "Node-RED"   "$ACTION_NODE_RED"    install_node_red    remove_node_red    || all_ok=false
  do_component "UFW"        "$ACTION_UFW"         install_ufw         remove_ufw         || all_ok=false

  # minden kész -> zene leállítása (kérésed szerint)
  stop_music

  print_summary

  section "Befejezés"
  if $all_ok; then
    echo -e "${GREEN}${BOLD}KÉSZ – minden lépés sikeres.${NC}"
  else
    echo -e "${YELLOW}${BOLD}KÉSZ – volt sikertelen lépés.${NC}"
    echo -e "${YELLOW}Nézd a logot:${NC} $LOGFILE"
  fi

  echo -e "${PURPLE}»${NC} Apache:      http://<szerver-ip>/ (ha telepítve)"
  echo -e "${PURPLE}»${NC} PHP info:     http://<szerver-ip>/info.php (ha telepítve)"
  echo -e "${PURPLE}»${NC} phpMyAdmin:   http://<szerver-ip>/phpmyadmin (ha telepítve)"
  echo -e "${PURPLE}»${NC} Node-RED:     http://<szerver-ip>:${NODE_RED_PORT}/ (ha telepítve)"
  echo -e "${PURPLE}»${NC} MQTT:         tcp/<szerver-ip>:1883 (ha telepítve)"
  echo

  $all_ok && exit 0 || exit 1
}

main "$@"
