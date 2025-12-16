#!/usr/bin/env bash
set -u
export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

############################################
# KONFIG
############################################
CONFIG_FILE="./config.conf"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
else
  echo "WARN: config.conf nem található, alapértelmezett értékekkel futok."
fi

: "${DRY_RUN:=false}"
: "${LOGFILE:=/var/log/showoff_installer.log}"

# ZENE
: "${ENABLE_MUSIC:=true}"
: "${MUSIC_PLAYER:=auto}"   # auto | mpg123 | ffplay
: "${MUSIC_VOLUME:=80}"

# MP3: script mappájából töltjük (mindegy honnan indítod)
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
: "${MUSIC_FILE:=$SCRIPT_DIR/Elevator Music (Kevin MacLeod) - Background Music (HD).mp3}"

############################################
# SZÍNEK
############################################
RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; BLUE="\e[34m"
PURPLE="\e[35m"; CYAN="\e[36m"; BOLD="\e[1m"; DIM="\e[2m"; NC="\e[0m"

############################################
# ROOT CHECK
############################################
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo -e "${RED}Root jogosultság szükséges.${NC}"
  echo "Futtasd így:"
  echo "  su -"
  echo "  ./install.sh"
  exit 1
fi

############################################
# LOG
############################################
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

############################################
# UI / SPINNER
############################################
spinner() {
  local pid="$1" text="$2"
  local spin='|/-\' i=0
  while kill -0 "$pid" 2>/dev/null; do
    i=$(( (i + 1) % 4 ))
    printf "\r${CYAN}${spin:$i:1}${NC} %s" "$text"
    sleep 0.1
  done
  printf "\r%s\r" " "
}

ask_choice() {
  # ask_choice "kérdés" -> echo I/T/K
  local q="$1"
  while true; do
    echo
    echo "$q"
    echo "  I) Telepítés"
    echo "  T) Törlés"
    echo "  K) Kihagyás"
    read -rp "Válasz (I/T/K): " a
    case "$a" in
      I|i) echo "I"; return 0;;
      T|t) echo "T"; return 0;;
      K|k) echo "K"; return 0;;
      *) echo "I / T / K";;
    esac
  done
}

############################################
# APT HELPERS
############################################
apt_update() { log "APT update"; run apt-get update -y; }
apt_install() { log "APT install: $*"; run apt-get install -y "$@"; }
apt_purge() { log "APT purge: $*"; run apt-get purge -y "$@"; }
apt_autoremove() { log "APT autoremove"; run apt-get autoremove -y; }

pkg_installed() { dpkg -s "$1" >/dev/null 2>&1; }

svc_enable_now() { run systemctl enable --now "$1" >/dev/null 2>&1; }
svc_disable_now() { run systemctl disable --now "$1" >/dev/null 2>&1 || true; }

############################################
# MP3 LEJÁTSZÓ (T=toggle, M=stop)
############################################
MUSIC_PID=""

music_pick_player() {
  local p=""
  if [[ "$MUSIC_PLAYER" == "mpg123" ]]; then p="mpg123"; fi
  if [[ "$MUSIC_PLAYER" == "ffplay" ]]; then p="ffplay"; fi
  if [[ "$MUSIC_PLAYER" == "auto" ]]; then
    command -v mpg123 >/dev/null 2>&1 && p="mpg123"
    [[ -z "$p" ]] && command -v ffplay >/dev/null 2>&1 && p="ffplay"
  fi
  echo "$p"
}

music_ensure_player() {
  local p
  p="$(music_pick_player)"
  [[ -n "$p" ]] && return 0
  warn "Nincs mpg123/ffplay. Telepítem a mpg123-at (MP3-hoz)."
  apt_install mpg123 || return 1
  return 0
}

music_start() {
  [[ "$ENABLE_MUSIC" != "true" ]] && return 0
  if [[ ! -f "$MUSIC_FILE" ]]; then
    warn "Zene fájl nem található: $MUSIC_FILE (kihagyom a zenét)"
    return 0
  fi
  if [[ -n "${MUSIC_PID:-}" ]] && kill -0 "$MUSIC_PID" 2>/dev/null; then
    return 0
  fi

  local p
  p="$(music_pick_player)"
  if [[ -z "$p" ]]; then
    music_ensure_player || { warn "Lejátszó telepítés nem sikerült (zene kihagyva)"; return 0; }
    p="$(music_pick_player)"
  fi

  log "Zene indítása: $p | $MUSIC_FILE"
  if [[ "$DRY_RUN" == "true" ]]; then
    warn "[DRY-RUN] MUSIC start"
    return 0
  fi

  if [[ "$p" == "mpg123" ]]; then
    local vol=$(( MUSIC_VOLUME * 32768 / 100 ))
    ( mpg123 -q --loop -1 -f "$vol" "$MUSIC_FILE" >/dev/null 2>&1 ) &
    MUSIC_PID=$!
  else
    ( ffplay -nodisp -loglevel quiet -loop 0 "$MUSIC_FILE" >/dev/null 2>&1 ) &
    MUSIC_PID=$!
  fi
  ok "Zene elindítva (T=toggle, M=stop)"
}

music_stop() {
  [[ "$ENABLE_MUSIC" != "true" ]] && return 0
  if [[ -n "${MUSIC_PID:-}" ]] && kill -0 "$MUSIC_PID" 2>/dev/null; then
    kill "$MUSIC_PID" 2>/dev/null || true
    sleep 0.2
    kill -9 "$MUSIC_PID" 2>/dev/null || true
    MUSIC_PID=""
    ok "Zene leállítva"
  fi
}

music_toggle() {
  if [[ -n "${MUSIC_PID:-}" ]] && kill -0 "$MUSIC_PID" 2>/dev/null; then
    music_stop
  else
    music_start
  fi
}

hotkey_loop() {
  [[ "$ENABLE_MUSIC" != "true" ]] && return 0
  while true; do
    if read -rsn1 -t 0.5 key; then
      case "$key" in
        [Tt]) music_toggle ;;
        [Mm]) music_stop ;;
        [Hh])
          echo
          echo -e "${BLUE}SÚGÓ:${NC} T=toggle zene | M=stop zene | Log: $LOGFILE"
          ;;
      esac
    fi
  done
}

cleanup() {
  music_stop
}
trap cleanup EXIT

############################################
# TELEPÍTÉS / TÖRLÉS FUNKCIÓK (régi logika)
############################################
install_apache() { apt_install apache2 || return 1; svc_enable_now apache2 || return 1; return 0; }
remove_apache() { svc_disable_now apache2; apt_purge apache2 || return 1; apt_autoremove || true; return 0; }

install_ssh() { apt_install openssh-server || return 1; svc_enable_now ssh || return 1; return 0; }
remove_ssh() { svc_disable_now ssh; apt_purge openssh-server || return 1; apt_autoremove || true; return 0; }

install_mosquitto() { apt_install mosquitto mosquitto-clients || return 1; svc_enable_now mosquitto || return 1; return 0; }
remove_mosquitto() { svc_disable_now mosquitto; apt_purge mosquitto mosquitto-clients || return 1; apt_autoremove || true; return 0; }

install_mariadb() { apt_install mariadb-server || return 1; svc_enable_now mariadb || return 1; return 0; }
remove_mariadb() { svc_disable_now mariadb; apt_purge mariadb-server || return 1; apt_autoremove || true; return 0; }

# PHP: Apache kötelező
install_php() {
  if ! pkg_installed apache2; then
    warn "PHP-hoz kell az Apache2. Telepítem az Apache2-t is."
    install_apache || return 1
  fi
  apt_install php libapache2-mod-php php-mysql || return 1
  run systemctl restart apache2 >/dev/null 2>&1 || true
  return 0
}
remove_php() { apt_purge php libapache2-mod-php php-mysql || return 1; apt_autoremove || true; return 0; }

install_ufw() {
  apt_install ufw || return 1
  run ufw allow OpenSSH || return 1
  run ufw allow 80/tcp || return 1
  run ufw allow 1880/tcp || return 1
  run ufw allow 1883/tcp || return 1
  run ufw --force enable || return 1
  return 0
}
remove_ufw() {
  run ufw --force disable >/dev/null 2>&1 || true
  apt_purge ufw || return 1
  apt_autoremove || true
  return 0
}

# Node-RED special
nr_installed() {
  command -v node-red >/dev/null 2>&1 || systemctl list-unit-files 2>/dev/null | grep -q '^nodered\.service'
}
install_node_red() {
  apt_install curl ca-certificates || return 1
  log "Node-RED telepítés (--confirm-root)"
  set +e
  curl -fsSL https://github.com/node-red/linux-installers/releases/latest/download/update-nodejs-and-nodered-deb \
    | bash -s -- --confirm-root
  set -e
  run systemctl daemon-reload >/dev/null 2>&1 || true
  run systemctl enable --now nodered.service >/dev/null 2>&1 || true
  systemctl is-active --quiet nodered 2>/dev/null
}
remove_node_red() {
  svc_disable_now nodered.service
  svc_disable_now nodered
  if command -v npm >/dev/null 2>&1; then
    run npm -g remove node-red >/dev/null 2>&1 || true
  fi
  rm -f /etc/systemd/system/nodered.service 2>/dev/null || true
  run systemctl daemon-reload >/dev/null 2>&1 || true
  return 0
}

############################################
# SHOW-OFF BANNER
############################################
clear
echo -e "${PURPLE}${BOLD}=========================================${NC}"
echo -e "${PURPLE}${BOLD}  SHOW-OFF SERVER INSTALLER (MENU + MP3) ${NC}"
echo -e "${PURPLE}${BOLD}=========================================${NC}"
echo -e "${BLUE}Logfile:${NC} $LOGFILE"
echo -e "${DIM}Zene: ENABLE_MUSIC=${ENABLE_MUSIC} | MUSIC_FILE=${MUSIC_FILE}${NC}"
echo -e "${DIM}Hotkeys: T=toggle zene | M=stop zene | H=súgó${NC}"
echo

############################################
# EREDMÉNYEK
############################################
declare -A RESULTS
set_result() { RESULTS["$1"]="$2"; }

run_action() {
  # run_action "Label" install/remove/skip "command"
  local label="$1" action="$2" cmd="$3"

  if [[ "$action" == "K" ]]; then
    set_result "$label" "KIHAGYVA"
    warn "$label kihagyva"
    return 0
  fi

  # telepítés/törlés fut spinnerrel + zene hotkey
  ( $cmd ) & pid=$!
  spinner "$pid" "$label: $( [[ "$action" == "I" ]] && echo "Telepítés" || echo "Törlés" )... (T/M)"
  wait "$pid"
  local rc=$?

  if [[ $rc -eq 0 ]]; then
    set_result "$label" "SIKERES"
    ok "$label OK"
    return 0
  else
    set_result "$label" "HIBA"
    warn "$label HIBA"
    return 1
  fi
}

############################################
# MAIN
############################################
hotkey_loop & HOTKEY_PID=$!
music_start

# APT update (régi scripthez hasonló)
( apt_update ) & pid=$!
spinner "$pid" "APT update... (T/M)"
wait "$pid" || warn "APT update sikertelen (internet/DNS/repo gond)."
echo

# MENÜ: minden elemnél kiírjuk, telepítve van-e, és kérjük az akciót
echo -e "${BOLD}Válaszd ki, mit csináljunk az elemekkel:${NC}"
echo -e "${DIM}(Ha telepítve van -> felajánlja a törlést is. PHP-hoz Apache kötelező.)${NC}"

# Apache2
apache_state="NINCS"; pkg_installed apache2 && apache_state="TELEPÍTVE"
echo; echo -e "${BLUE}Apache2:${NC} $apache_state"
a_apache="$(ask_choice "Apache2 művelet?")"
if [[ "$a_apache" == "T" && "$(pkg_installed apache2; echo $?)" -ne 0 ]]; then
  warn "Apache2 nincs telepítve, törlés kihagyva."
  a_apache="K"
fi
run_action "Apache2" "$a_apache" "$( [[ "$a_apache" == "I" ]] && echo install_apache || echo remove_apache )"

# SSH
ssh_state="NINCS"; pkg_installed openssh-server && ssh_state="TELEPÍTVE"
echo; echo -e "${BLUE}SSH:${NC} $ssh_state"
a_ssh="$(ask_choice "SSH művelet?")"
if [[ "$a_ssh" == "T" && "$(pkg_installed openssh-server; echo $?)" -ne 0 ]]; then
  warn "SSH nincs telepítve, törlés kihagyva."
  a_ssh="K"
fi
run_action "SSH" "$a_ssh" "$( [[ "$a_ssh" == "I" ]] && echo install_ssh || echo remove_ssh )"

# Mosquitto
mqtt_state="NINCS"; pkg_installed mosquitto && mqtt_state="TELEPÍTVE"
echo; echo -e "${BLUE}Mosquitto:${NC} $mqtt_state"
a_mqtt="$(ask_choice "Mosquitto művelet?")"
if [[ "$a_mqtt" == "T" && "$(pkg_installed mosquitto; echo $?)" -ne 0 ]]; then
  warn "Mosquitto nincs telepítve, törlés kihagyva."
  a_mqtt="K"
fi
run_action "Mosquitto" "$a_mqtt" "$( [[ "$a_mqtt" == "I" ]] && echo install_mosquitto || echo remove_mosquitto )"

# Node-RED
nr_state="NINCS"; nr_installed && nr_state="TELEPÍTVE"
echo; echo -e "${BLUE}Node-RED:${NC} $nr_state"
a_nr="$(ask_choice "Node-RED művelet?")"
if [[ "$a_nr" == "T" && "$nr_state" == "NINCS" ]]; then
  warn "Node-RED nincs telepítve, törlés kihagyva."
  a_nr="K"
fi
run_action "Node-RED" "$a_nr" "$( [[ "$a_nr" == "I" ]] && echo install_node_red || echo remove_node_red )"

# MariaDB
db_state="NINCS"; pkg_installed mariadb-server && db_state="TELEPÍTVE"
echo; echo -e "${BLUE}MariaDB:${NC} $db_state"
a_db="$(ask_choice "MariaDB művelet?")"
if [[ "$a_db" == "T" && "$(pkg_installed mariadb-server; echo $?)" -ne 0 ]]; then
  warn "MariaDB nincs telepítve, törlés kihagyva."
  a_db="K"
fi
run_action "MariaDB" "$a_db" "$( [[ "$a_db" == "I" ]] && echo install_mariadb || echo remove_mariadb )"

# PHP (Apache függőség)
php_state="NINCS"; (pkg_installed php || pkg_installed libapache2-mod-php) && php_state="TELEPÍTVE"
echo; echo -e "${BLUE}PHP:${NC} $php_state ${DIM}(Apache2 kötelező)${NC}"
a_php="$(ask_choice "PHP művelet?")"
if [[ "$a_php" == "T" && "$php_state" == "NINCS" ]]; then
  warn "PHP nincs telepítve, törlés kihagyva."
  a_php="K"
fi
run_action "PHP" "$a_php" "$( [[ "$a_php" == "I" ]] && echo install_php || echo remove_php )"

# UFW
ufw_state="NINCS"; pkg_installed ufw && ufw_state="TELEPÍTVE"
echo; echo -e "${BLUE}UFW:${NC} $ufw_state"
a_ufw="$(ask_choice "UFW művelet?")"
if [[ "$a_ufw" == "T" && "$(pkg_installed ufw; echo $?)" -ne 0 ]]; then
  warn "UFW nincs telepítve, törlés kihagyva."
  a_ufw="K"
fi
run_action "UFW" "$a_ufw" "$( [[ "$a_ufw" == "I" ]] && echo install_ufw || echo remove_ufw )"

# cleanup háttér
kill "$HOTKEY_PID" 2>/dev/null || true
music_stop

############################################
# SUMMARY + HAJRÁ LILÁK + NÉV
############################################
echo
echo "================================="
echo "  TELEPÍTÉSI ÖSSZEFOGLALÓ"
echo "================================="
any_fail=0
for k in "${!RESULTS[@]}"; do
  echo "$k : ${RESULTS[$k]}"
  [[ "${RESULTS[$k]}" == "HIBA" ]] && any_fail=1
done
echo

if [[ "$any_fail" -eq 0 ]]; then
  echo -e "${GREEN}KÉSZ – minden lépés rendben lefutott.${NC}"
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
  exit 1
fi
