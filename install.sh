#!/usr/bin/env bash
set -u
set -o pipefail

export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export SDL_AUDIODRIVER=alsa

############################################
# KONFIG
############################################
LOGFILE="/var/log/showoff_installer.log"

ENABLE_MUSIC=true
YOUTUBE_URL="https://www.youtube.com/watch?v=0Wi8Fv0AJA4&list=RD0Wi8Fv0AJA4&start_radio=1"
MUSIC_VOLUME=80

############################################
# SZÍNEK
############################################
RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; BLUE="\e[34m"
PURPLE="\e[35m"; CYAN="\e[36m"; BOLD="\e[1m"; NC="\e[0m"

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

############################################
# UI SEGÉDEK
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
# APT / CHECK
############################################
apt_install(){ apt-get install -y "$@"; }
apt_update(){ apt-get update -y; }
pkg_installed(){ dpkg -s "$1" >/dev/null 2>&1; }
svc_on(){ systemctl enable --now "$1" >/dev/null 2>&1; }

have_internet(){
  command -v curl >/dev/null 2>&1 || apt_install curl >/dev/null 2>&1 || true
  curl -fsSL --max-time 4 https://deb.debian.org >/dev/null 2>&1
}

############################################
# YOUTUBE ZENE (csendes)
############################################
MUSIC_PID=""

ensure_music_tools(){
  command -v yt-dlp >/dev/null 2>&1 || apt_install yt-dlp
  command -v ffplay >/dev/null 2>&1 || apt_install ffmpeg
}

music_start(){
  [[ "$ENABLE_MUSIC" != true ]] && return
  [[ -n "${MUSIC_PID:-}" ]] && kill -0 "$MUSIC_PID" 2>/dev/null && return
  if ! have_internet; then
    warn "Nincs internet – zene kihagyva."
    ENABLE_MUSIC=false
    return
  fi
  ensure_music_tools
  (
    yt-dlp -f bestaudio -o - "$YOUTUBE_URL" 2>/dev/null |
    ffplay -nodisp -loglevel error -autoexit -loop 0 -volume "$MUSIC_VOLUME" - 2>/dev/null
  ) &
  MUSIC_PID=$!
  ok "Zene elindult (T=toggle, M=stop, H=súgó)"
}

music_stop(){
  if [[ -n "${MUSIC_PID:-}" ]] && kill -0 "$MUSIC_PID" 2>/dev/null; then
    kill "$MUSIC_PID" 2>/dev/null || true
    sleep 0.2
    kill -9 "$MUSIC_PID" 2>/dev/null || true
    MUSIC_PID=""
  fi
}

music_toggle(){ if kill -0 "$MUSIC_PID" 2>/dev/null; then music_stop; else music_start; fi; }

hotkeys(){
  while true; do
    if read -rsn1 -t 0.4 k; then
      case "$k" in
        [Tt]) music_toggle ;;
        [Mm]) music_stop ;;
        [Hh]) echo -e "${BLUE}T=toggle  M=stop  Log=$LOGFILE${NC}" ;;
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
    install_apache
  fi
  apt_install php libapache2-mod-php php-mysql
  systemctl restart apache2 >/dev/null 2>&1 || true
}

nr_installed(){
  command -v node-red >/dev/null 2>&1 || systemctl list-unit-files | grep -q '^nodered\.service'
}
install_node_red(){
  apt_install curl ca-certificates
  if ! have_internet; then
    warn "Nincs internet – Node-RED kihagyva."
    return 1
  fi
  curl -fsSL https://github.com/node-red/linux-installers/releases/latest/download/update-nodejs-and-nodered-deb |
    bash -s -- --confirm-root
  systemctl daemon-reload
  svc_on nodered.service
}

install_ufw(){
  apt_install ufw
  ufw allow OpenSSH
  ufw allow 80/tcp
  ufw allow 1880/tcp
  ufw allow 1883/tcp
  ufw --force enable
}

############################################
# KÖRBE MOZGÓ HAJRÁ ÚJPEST (JAVÍTOTT)
############################################
animate_hajra() {
  local text="HAJRÁ ÚJPEST"
  local color="\e[35m"
  local reset="\e[0m"

  if [[ -z "${TERM:-}" || "$TERM" == "dumb" ]]; then
    echo -e "${color}${text}${reset}"
    return 0
  fi

  local positions=(
    "0 -4" "2 -3" "3 -2" "4 0" "3 2" "2 3"
    "0 4" "-2 3" "-3 2" "-4 0" "-3 -2" "-2 -3"
  )

  local rows cols
  rows="$(tput lines 2>/dev/null || echo 24)"
  cols="$(tput cols 2>/dev/null || echo 80)"
  local cy=$(( rows / 2 ))
  local cx=$(( (cols - ${#text}) / 2 ))

  tput civis 2>/dev/null || true

  for ((loop=0; loop<3; loop++)); do
    for pos in "${positions[@]}"; do
      printf "\033[2J\033[H"
      read -r dx dy <<< "$pos"

      local y=$(( cy + dy ))
      local x=$(( cx + dx ))
      (( y < 0 )) && y=0
      (( x < 0 )) && x=0

      tput cup "$y" "$x" 2>/dev/null || printf "\033[%d;%dH" "$((y+1))" "$((x+1))"
      printf "%b%s%b" "$color" "$text" "$reset"
      sleep 0.10
    done
  done

  tput cnorm 2>/dev/null || true
  printf "\033[2J\033[H"
}

############################################
# BANNER
############################################
clear
echo -e "${PURPLE}${BOLD}=========================================${NC}"
echo -e "${PURPLE}${BOLD}  SHOW-OFF SERVER INSTALLER              ${NC}"
echo -e "${PURPLE}${BOLD}=========================================${NC}"
echo -e "${BLUE}Hotkeys:${NC} T=toggle  M=stop  H=súgó"
echo

############################################
# FUTTATÁS
############################################
hotkeys & HOTKEY_PID=$!
music_start

apt_update

run_component(){
  local name="$1" check="$2" install="$3"
  echo -e "${BLUE}==> $name${NC}"
  if eval "$check"; then
    warn "$name már telepítve."
    ask_yn "Újratelepíted?" || { ok "$name kihagyva"; echo; return; }
  else
    ask_yn "$name nincs telepítve. Telepítsem?" || { warn "$name kihagyva"; echo; return; }
  fi
  ( eval "$install" ) & pid=$!
  spinner "$pid" "$name telepítése..."
  wait "$pid" && ok "$name kész" || warn "$name hiba"
  echo
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
# SHOW-OFF VÉGE
############################################
animate_hajra

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
