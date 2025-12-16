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

# MP3: mindig a script mappájából
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

ask_yes_no() {
  local q="$1"
  while true; do
    read -rp "$q (i/n): " a
    case "$a" in
      i|I) return 0 ;;
      n|N) return 1 ;;
      *) echo "i vagy n" ;;
    esac
  done
}

############################################
# APT HELPERS
############################################
apt_update() { log "APT update"; run apt-get update -y; }
apt_install() { log "APT install: $*"; run apt-get install -y "$@"; }
pkg_installed() { dpkg -s "$1" >/dev/null 2>&1; }
svc_enable_now() { run systemctl enable --now "$1" >/dev/null 2>&1; }

############################################
# MP3 LEJÁTSZÓ (T=toggle, M=stop, H=súgó)
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
  ok "Zene elindítva (T=toggle, M=stop, H=súgó)"
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

cleanup() { music_stop; }
trap cleanup EXIT

############################################
# TELEPÍTŐ FUNKCIÓK (régi logika)
############################################
install_apache() { apt_install apache2 || return 1; svc_enable_now apache2 || return 1; return 0; }
install_ssh() { apt_install openssh-server || return 1; svc_enable_now ssh || return 1; return 0; }
install_mosquitto() { apt_install mosquitto mosquitto-clients || return 1; svc_enable_now mosquitto || return 1; return 0; }
install_mariadb() { apt_install mariadb-server || return 1; svc_enable_now mariadb || return 1; return 0; }

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

install_ufw() {
  apt_install ufw || return 1
  run ufw allow OpenSSH || return 1
  run ufw allow 80/tcp || return 1
  run ufw allow 1880/tcp || return 1
  run ufw allow 1883/tcp || return 1
  run ufw --force enable || return 1
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

############################################
# SHOW-OFF BANNER
############################################
clear
echo -e "${PURPLE}${BOLD}=========================================${NC}"
echo -e "${PURPLE}${BOLD}  SHOW-OFF SERVER INSTALLER (2 OP) + MP3 ${NC}"
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

run_install_if_missing() {
  # name, check_command, install_command
  local name="$1"
  local check_cmd="$2"
  local install_cmd="$3"

  echo -e "${BLUE}${BOLD}==> ${name}${NC}"

  if eval "$check_cmd"; then
    set_result "$name" "KIHAGYVA (már telepítve)"
    ok "$name már telepítve -> kihagyva"
    echo
    return 0
  fi

  if ! ask_yes_no "$name nincs telepítve. Telepítsem?"; then
    set_result "$name" "KIHAGYVA (user döntés)"
    warn "$name kihagyva (nem kérted)"
    echo
    return 0
  fi

  ( eval "$install_cmd" ) & pid=$!
  spinner "$pid" "Telepítés: $name... (T/M)"
  wait "$pid"
  local rc=$?

  if [[ $rc -eq 0 ]]; then
    set_result "$name" "SIKERES"
    ok "$name OK"
  else
    set_result "$name" "HIBA"
    warn "$name HIBA"
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

run_install_if_missing "Apache2"   "pkg_installed apache2"          "install_apache"
run_install_if_missing "SSH"       "pkg_installed openssh-server"   "install_ssh"
run_install_if_missing "Mosquitto" "pkg_installed mosquitto"        "install_mosquitto"
run_install_if_missing "Node-RED"  "nr_installed"                   "install_node_red"
run_install_if_missing "MariaDB"   "pkg_installed mariadb-server"   "install_mariadb"
run_install_if_missing "PHP"       "(pkg_installed php || pkg_installed libapache2-mod-php)" "install_php"
run_install_if_missing "UFW"       "pkg_installed ufw"              "install_ufw"

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
