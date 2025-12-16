#!/usr/bin/env bash
# SHOW-OFF SERVER INSTALLER (VirtualBox/Debian/Ubuntu) + MP3 music controls
# Installs: Apache2, SSH, Mosquitto(+clients), Node-RED, MariaDB, PHP, UFW
# Music: MP3 playback during install with start/stop/toggle.

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
: "${INSTALL_APACHE:=true}"
: "${INSTALL_SSH:=true}"
: "${INSTALL_NODE_RED:=true}"
: "${INSTALL_MOSQUITTO:=true}"
: "${INSTALL_MARIADB:=true}"
: "${INSTALL_PHP:=true}"
: "${INSTALL_UFW:=true}"
: "${LOGFILE:=/var/log/showoff_installer.log}"

# ==== ZENE ====
: "${ENABLE_MUSIC:=true}"
# MP3 fájl: tedd a script mellé, vagy módosítsd ezt az útvonalat.
: "${MUSIC_FILE:=./Elevator Music (Kevin MacLeod) - Background Music (HD).mp3}"
: "${MUSIC_PLAYER:=auto}"   # auto | mpg123 | ffplay
: "${MUSIC_VOLUME:=80}"     # mpg123 volume: 0-100

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
# UI / SPINNER (csak látvány)
############################################
spinner() {
  local pid="$1"; local text="$2"
  local spin='|/-\' i=0
  while kill -0 "$pid" 2>/dev/null; do
    i=$(( (i + 1) % 4 ))
    printf "\r${CYAN}${spin:$i:1}${NC} %s" "$text"
    sleep 0.1
  done
  printf "\r%s\r" " "
}

############################################
# APT HELPERS
############################################
apt_update() { log "APT csomaglista frissítése"; run apt-get update -y; }
apt_install() { log "Csomag telepítés: $*"; run apt-get install -y "$@"; }

############################################
# MP3 LEJÁTSZÓ (start/stop/toggle)
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

music_ensure_player_installed() {
  local p
  p="$(music_pick_player)"
  [[ -n "$p" ]] && return 0

  warn "Nincs mpg123/ffplay. Telepítem a mpg123-at (MP3 lejátszáshoz)."
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
    music_ensure_player_installed || { warn "Nem tudtam lejátszót telepíteni (zene kihagyva)"; return 0; }
    p="$(music_pick_player)"
  fi

  log "Zene indítása: player=$p file=$MUSIC_FILE"
  if [[ "$DRY_RUN" == "true" ]]; then
    warn "[DRY-RUN] MUSIC start ($p \"$MUSIC_FILE\")"
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

  ok "Zene elindítva. (T=toggle, M=stop)"
  return 0
}

music_stop() {
  [[ "$ENABLE_MUSIC" != "true" ]] && return 0
  if [[ -n "${MUSIC_PID:-}" ]] && kill -0 "$MUSIC_PID" 2>/dev/null; then
    log "Zene leállítása (PID: $MUSIC_PID)"
    kill "$MUSIC_PID" 2>/dev/null || true
    sleep 0.2
    kill -9 "$MUSIC_PID" 2>/dev/null || true
    MUSIC_PID=""
    ok "Zene leállítva"
  fi
  return 0
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
      esac
    fi
  done
}

cleanup() {
  music_stop
}
trap cleanup EXIT

############################################
# TELEPÍTŐ FUNKCIÓK
############################################
install_apache() { apt_install apache2 || return 1; run systemctl enable --now apache2 || return 1; return 0; }
install_ssh() { apt_install openssh-server || return 1; run systemctl enable --now ssh || return 1; return 0; }
install_mosquitto() { apt_install mosquitto mosquitto-clients || return 1; run systemctl enable --now mosquitto || return 1; return 0; }
install_mariadb() { apt_install mariadb-server || return 1; run systemctl enable --now mariadb || return 1; return 0; }
install_php() { apt_install php libapache2-mod-php php-mysql || return 1; run systemctl restart apache2 || return 1; return 0; }
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

############################################
# BANNER
############################################
clear
echo -e "${PURPLE}${BOLD}=========================================${NC}"
echo -e "${PURPLE}${BOLD}  SHOW-OFF SERVER INSTALLER (MP3)        ${NC}"
echo -e "${PURPLE}${BOLD}=========================================${NC}"
echo -e "${BLUE}Logfile:${NC} $LOGFILE"
echo -e "${DIM}Zene: ENABLE_MUSIC=${ENABLE_MUSIC} | MUSIC_FILE=${MUSIC_FILE}${NC}"
echo -e "${DIM}Hotkeys: T=toggle zene | M=stop zene${NC}"
echo

############################################
# EREDMÉNYEK
############################################
declare -A RESULTS
set_result() { RESULTS["$1"]="$2"; }

run_install() {
  local var="$1" label="$2" func="$3"
  echo -e "${BLUE}${BOLD}==> ${label}${NC}"

  if [[ "${!var:-false}" == "true" ]]; then
    ( "$func" ) & pid=$!
    spinner "$pid" "Telepítés: $label (T/M)"
    wait "$pid"
    local rc=$?
    if [[ $rc -eq 0 ]]; then
      set_result "$label" "SIKERES"
      ok "$label OK"
    else
      set_result "$label" "HIBA"
      warn "$label HIBA"
    fi
  else
    set_result "$label" "KIHAGYVA"
    warn "$label kihagyva (config: $var=false)"
  fi
  echo
}

############################################
# FUTTATÁS
############################################
hotkey_loop & HOTKEY_PID=$!
music_start

( apt_update ) & pid=$!
spinner "$pid" "APT update... (T/M)"
wait "$pid" || warn "APT update sikertelen (internet/DNS/repo gond)."
echo

run_install INSTALL_APACHE     "Apache2"   install_apache
run_install INSTALL_SSH        "SSH"       install_ssh
run_install INSTALL_MOSQUITTO  "Mosquitto" install_mosquitto
run_install INSTALL_NODE_RED   "Node-RED"  install_node_red
run_install INSTALL_MARIADB    "MariaDB"   install_mariadb
run_install INSTALL_PHP        "PHP"       install_php
run_install INSTALL_UFW        "UFW"       install_ufw

kill "$HOTKEY_PID" 2>/dev/null || true
music_stop

############################################
# SUMMARY + HAJRÁ LILÁK
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
