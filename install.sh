#!/usr/bin/env bash
set -u
set -o pipefail

export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export SDL_AUDIODRIVER=alsa

############################################
# KONFIG (config.conf opcionális)
############################################
CONFIG_FILE="./config.conf"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

LOGFILE="${LOGFILE:-/var/log/showoff_installer.log}"
DRY_RUN="${DRY_RUN:-false}"

# ZENE – YOUTUBE
ENABLE_MUSIC="${ENABLE_MUSIC:-true}"
YOUTUBE_URL="${YOUTUBE_URL:-https://www.youtube.com/watch?v=0Wi8Fv0AJA4&list=RD0Wi8Fv0AJA4&start_radio=1}"
MUSIC_VOLUME="${MUSIC_VOLUME:-80}"

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
  echo "Futtasd: su - && ./install.sh"
  exit 1
fi

############################################
# LOG
############################################
mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true
touch "$LOGFILE" 2>/dev/null || true

log(){ echo "$(date '+%F %T') | $1" | tee -a "$LOGFILE" >/dev/null; }
ok(){ echo -e "${GREEN}✔ $1${NC}"; log "OK: $1"; }
warn(){ echo -e "${YELLOW}⚠ $1${NC}"; log "WARN: $1"; }
info(){ echo -e "${BLUE}i${NC} $1"; log "INFO: $1"; }

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    warn "[DRY-RUN] $*"
    return 0
  fi
  "$@"
}

############################################
# UI
############################################
spinner() {
  local pid="$1" text="$2" spin='|/-\' i=0
  while kill -0 "$pid" 2>/dev/null; do
    i=$(( (i+1)%4 ))
    printf "\r${CYAN}${spin:$i:1}${NC} %s" "$text"
    sleep 0.1
  done
  printf "\r%s\r" " "
}

ask_yn(){
  while true; do
    read -rp "$1 (i/n): " a
    case "$a" in i|I) return 0;; n|N) return 1;; *) echo "i vagy n";; esac
  done
}

############################################
# APT + rendszer ellenőrzések
############################################
apt_install(){ run apt-get install -y "$@"; }
apt_update(){ run apt-get update -y; }

pkg_installed(){ dpkg -s "$1" >/dev/null 2>&1; }
svc_on(){ run systemctl enable --now "$1" >/dev/null 2>&1; }

have_internet() {
  # gyors, nem ICMP-függő: DNS+HTTPS jelleg
  command -v curl >/dev/null 2>&1 || apt_install curl >/dev/null 2>&1 || true
  curl -fsSL --max-time 4 https://deb.debian.org >/dev/null 2>&1 && return 0
  curl -fsSL --max-time 4 https://archive.ubuntu.com >/dev/null 2>&1 && return 0
  return 1
}

port_in_use() {
  # port_in_use 1880
  local p="$1"
  ss -lnt 2>/dev/null | awk '{print $4}' | grep -E "[:.]$p$" >/dev/null 2>&1
}

show_port_warnings() {
  local any=0
  for p in 80 1880 1883; do
    if port_in_use "$p"; then
      warn "FIGYELEM: a port foglalt: $p (lehet, hogy már fut valami azon a porton)"
      any=1
    fi
  done
  [[ $any -eq 0 ]] && ok "Portok rendben (80/1880/1883 nem foglaltak a listen oldalon)"
}

get_ip() {
  # első nem-loopback IPv4
  hostname -I 2>/dev/null | awk '{print $1}'
}

############################################
# YOUTUBE ZENE (csendes ALSA)
############################################
MUSIC_PID=""

ensure_music_tools(){
  command -v yt-dlp >/dev/null 2>&1 || apt_install yt-dlp
  command -v ffplay >/dev/null 2>&1 || apt_install ffmpeg
}

music_start(){
  [[ "$ENABLE_MUSIC" != true ]] && return 0
  [[ -n "${MUSIC_PID:-}" ]] && kill -0 "$MUSIC_PID" 2>/dev/null && return 0

  # ha nincs net, ne próbálkozzon
  if ! have_internet; then
    warn "Nincs internet -> YouTube zene kikapcsolva (a telepítés megy tovább)."
    ENABLE_MUSIC=false
    return 0
  fi

  ensure_music_tools || { warn "Zene eszközök telepítése sikertelen -> zene kihagyva"; return 0; }

  log "YouTube zene indítása: $YOUTUBE_URL"
  (
    yt-dlp -f bestaudio -o - "$YOUTUBE_URL" 2>/dev/null |
    ffplay -nodisp -loglevel error -autoexit -loop 0 -volume "$MUSIC_VOLUME" - 2>/dev/null
  ) &
  MUSIC_PID=$!
  ok "Zene elindult (T=toggle, M=stop, H=súgó)"
  return 0
}

music_stop(){
  if [[ -n "${MUSIC_PID:-}" ]] && kill -0 "$MUSIC_PID" 2>/dev/null; then
    kill "$MUSIC_PID" 2>/dev/null || true
    sleep 0.2
    kill -9 "$MUSIC_PID" 2>/dev/null || true
    MUSIC_PID=""
    ok "Zene leállítva"
  fi
  return 0
}

music_toggle(){
  if [[ -n "${MUSIC_PID:-}" ]] && kill -0 "$MUSIC_PID" 2>/dev/null; then
    music_stop
  else
    music_start
  fi
}

hotkeys(){
  while true; do
    if read -rsn1 -t 0.5 k; then
      case "$k" in
        [Tt]) music_toggle ;;
        [Mm]) music_stop ;;
        [Hh])
          echo -e "${BLUE}SÚGÓ:${NC} T=toggle zene | M=stop zene | Log: $LOGFILE | DRY_RUN=$DRY_RUN"
          ;;
      esac
    fi
  done
}

trap music_stop EXIT

############################################
# TELEPÍTŐK
############################################
install_apache(){ apt_install apache2 && svc_on apache2; }
install_ssh(){ apt_install openssh-server && svc_on ssh; }
install_mosquitto(){ apt_install mosquitto mosquitto-clients && svc_on mosquitto; }
install_mariadb(){ apt_install mariadb-server && svc_on mariadb; }

install_php(){
  if ! pkg_installed apache2; then
    warn "PHP-hoz kell Apache2 – telepítem."
    install_apache || return 1
  fi
  apt_install php libapache2-mod-php php-mysql
  run systemctl restart apache2 >/dev/null 2>&1 || true
}

nr_installed(){
  command -v node-red >/dev/null 2>&1 || systemctl list-unit-files 2>/dev/null | grep -q '^nodered\.service'
}
install_node_red(){
  apt_install curl ca-certificates
  # ha nincs net, ne induljon el feleslegesen
  if ! have_internet; then
    warn "Nincs internet -> Node-RED telepítés kihagyva (GitHub kell hozzá)."
    return 1
  fi
  curl -fsSL https://github.com/node-red/linux-installers/releases/latest/download/update-nodejs-and-nodered-deb |
    bash -s -- --confirm-root
  run systemctl daemon-reload >/dev/null 2>&1 || true
  svc_on nodered.service || true
}

install_ufw(){
  apt_install ufw
  run ufw allow OpenSSH
  run ufw allow 80/tcp
  run ufw allow 1880/tcp
  run ufw allow 1883/tcp
  run ufw --force enable
}

############################################
# SHOW-OFF BANNER
############################################
clear
echo -e "${PURPLE}${BOLD}=========================================${NC}"
echo -e "${PURPLE}${BOLD}  SHOW-OFF SERVER INSTALLER (PRO)        ${NC}"
echo -e "${PURPLE}${BOLD}=========================================${NC}"
echo -e "${BLUE}Logfile:${NC} $LOGFILE"
echo -e "${DIM}Hotkeys: T=toggle zene | M=stop | H=súgó${NC}"
echo -e "${DIM}DRY_RUN=${DRY_RUN}${NC}"
echo

############################################
# ELŐZETES CHECK (praktikus)
############################################
info "Előzetes ellenőrzések..."
show_port_warnings
if have_internet; then ok "Internet: OK"; else warn "Internet: NINCS (YouTube zene és Node-RED problémás lehet)"; fi
echo

############################################
# FUTTATÁS
############################################
hotkeys & HOTKEY_PID=$!
music_start

info "APT update..."
apt_update || warn "APT update hiba (repo/DNS)."

run_component(){
  local name="$1" check="$2" install="$3"
  echo -e "${BLUE}${BOLD}==> $name${NC}"

  if eval "$check"; then
    warn "$name már telepítve."
    ask_yn "Újratelepíted?" || { ok "$name kihagyva"; echo; return 0; }
  else
    ask_yn "$name nincs telepítve. Telepítsem?" || { warn "$name kihagyva"; echo; return 0; }
  fi

  ( eval "$install" ) & pid=$!
  spinner "$pid" "$name telepítése... (T/M)"
  if wait "$pid"; then
    ok "$name kész"
  else
    warn "$name hiba"
  fi
  echo
  return 0
}

run_component "Apache2"   "pkg_installed apache2"        "install_apache"
run_component "SSH"       "pkg_installed openssh-server" "install_ssh"
run_component "Mosquitto" "pkg_installed mosquitto"      "install_mosquitto"
run_component "Node-RED"  "nr_installed"                 "install_node_red"
run_component "MariaDB"   "pkg_installed mariadb-server" "install_mariadb"
run_component "PHP"       "(pkg_installed php || pkg_installed libapache2-mod-php)" "install_php"
run_component "UFW"       "pkg_installed ufw"            "install_ufw"

kill "$HOTKEY_PID" 2>/dev/null || true
music_stop

############################################
# HEALTH CHECK + PRAKTIKUS INFÓK
############################################
echo -e "${BOLD}Szolgáltatás állapot (health-check):${NC}"
for s in apache2 ssh mosquitto mariadb nodered; do
  if systemctl is-active --quiet "$s" 2>/dev/null; then
    ok "$s RUNNING"
  else
    warn "$s NEM FUT"
  fi
done
echo

echo -e "${BOLD}Verziók (ha elérhető):${NC}"
command -v apache2 >/dev/null 2>&1 && apache2 -v | head -n1 || true
command -v php >/dev/null 2>&1 && php -v | head -n1 || true
command -v node >/dev/null 2>&1 && node -v || true
command -v npm >/dev/null 2>&1 && npm -v || true
command -v mariadb >/dev/null 2>&1 && mariadb --version | head -n1 || true
echo

IP="$(get_ip)"
echo -e "${BOLD}Következő lépések:${NC}"
if [[ -n "${IP:-}" ]]; then
  echo "Apache:   http://$IP"
  echo "Node-RED: http://$IP:1880"
else
  echo "IP nem olvasható. Próbáld: hostname -I"
fi
echo "Log: $LOGFILE"
echo

############################################
# HAJRÁ LILÁK
############################################
echo -e "${PURPLE}"
cat << "EOF"
██╗  ██╗ █████╗      ██╗██████╗  █████╗     ██╗     ██╗██╗      █████╗ ██╗  ██╗
██║  ██║██╔══██╗     ██║██╔══██╗██╔══██╗    ██║     ██║██║     ██╔══██╗██║ ██╔╝
███████║███████║     ██║██████╔╝███████║    ██║     ██║██║     ███████║█████╔╝
██╔══██║██╔══██║██   ██║██╔══██╗██╔══██║    ██║     ██║██║     ██╔══██║██╔═██╗
██║  ██║██║  ██║╚█████╔╝██║  ██║██║  ██║    ███████╗██║███████╗██║  ██║██║  ██╗
╚═╝  ╚═╝╚═╝  ╚═╝ ╚════╝ ╚═╝  ╚═╝╚═╝  ╚═╝    ╚══════╝╚═╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝
EOF
echo -e "${PURPLE}(Stahl Dávid Jenő)${NC}"
