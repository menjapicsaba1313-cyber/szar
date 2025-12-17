#!/usr/bin/env bash
set -u
set -o pipefail

export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

############################################
# KONFIG
############################################
LOGFILE="/var/log/showoff_installer.log"
MUSIC_LOG="/var/log/showoff_music.log"

ENABLE_MUSIC=true
YOUTUBE_URL="https://www.youtube.com/watch?v=0Wi8Fv0AJA4&list=RD0Wi8Fv0AJA4&start_radio=1"
MUSIC_VOLUME=80

############################################
# ÁLLAPOTOK (összegzéshez)
############################################
declare -A COMPONENT_STATUS
# értékek: ok | skipped | error | removed

############################################
# HOTKEYS INPUT ÜTKÖZÉS FIX
############################################
HOTKEYS_PAUSED=0

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
touch "$MUSIC_LOG" 2>/dev/null || true

log(){ echo "$(date '+%F %T') | $1" | tee -a "$LOGFILE" >/dev/null; }
ok(){   echo -e "${GREEN}✔ $1${NC}"; log "OK: $1"; }
warn(){ echo -e "${YELLOW}⚠ $1${NC}"; log "WARN: $1"; }
err(){  echo -e "${RED}✖ $1${NC}"; log "ERR: $1"; }

############################################
# UI SEGÉDEK
############################################
hr(){ echo -e "${DIM}────────────────────────────────────────────────────────────${NC}"; }
title(){
  clear
  echo -e "${PURPLE}${BOLD}╔════════════════════════════════════════════════════════════╗${NC}"
  printf  "${PURPLE}${BOLD}║%-60s║${NC}\n" "  SHOW-OFF SERVER INSTALLER"
  echo -e "${PURPLE}${BOLD}╚════════════════════════════════════════════════════════════╝${NC}"
  echo -e "${BLUE}Hotkeys:${NC} T=toggle zene  M=stop zene  H=súgó"
  echo -e "${DIM}Log:${NC} $LOGFILE"
  echo -e "${DIM}Music log:${NC} $MUSIC_LOG"
  echo
}

spinner() {
  local pid="$1" text="$2" spin='|/-\' i=0
  while kill -0 "$pid" 2>/dev/null; do
    i=$(( (i+1)%4 ))
    printf "\r${CYAN}${spin:$i:1}${NC} %s" "$text"
    sleep 0.1
  done
  printf "\r%s\r" " "
}

############################################
# INPUT / MENÜK (HOTKEYS-Pause-al)
############################################
ask_yn(){
  HOTKEYS_PAUSED=1
  while true; do
    read -rp "$1 (i/n): " a
    case "${a:-}" in
      i|I) HOTKEYS_PAUSED=0; return 0;;
      n|N) HOTKEYS_PAUSED=0; return 1;;
      *) echo "i vagy n";;
    esac
  done
}

ask_action_installed(){
  HOTKEYS_PAUSED=1
  while true; do
    read -rp "$1 [i]=futtat/újra  [t]=töröl  [n]=kihagy: " a
    case "${a:-}" in
      i|I) HOTKEYS_PAUSED=0; echo "install"; return 0;;
      t|T) HOTKEYS_PAUSED=0; echo "remove";  return 0;;
      n|N) HOTKEYS_PAUSED=0; echo "skip";    return 0;;
      *) echo "i / t / n";;
    esac
  done
}

ask_action_not_installed(){
  HOTKEYS_PAUSED=1
  while true; do
    read -rp "$1 [i]=telepít  [n]=kihagy: " a
    case "${a:-}" in
      i|I) HOTKEYS_PAUSED=0; echo "install"; return 0;;
      n|N) HOTKEYS_PAUSED=0; echo "skip";    return 0;;
      *) echo "i / n";;
    esac
  done
}

############################################
# APT / CHECK
############################################
apt_install(){ apt-get install -y "$@"; }
apt_update(){ apt-get update -y; }
apt_purge(){ apt-get purge -y "$@"; }
apt_autoremove(){ apt-get autoremove -y; }
pkg_installed(){ dpkg -s "$1" >/dev/null 2>&1; }
svc_on(){ systemctl enable --now "$1" >/dev/null 2>&1; }
svc_off(){ systemctl disable --now "$1" >/dev/null 2>&1 || true; }

have_internet(){
  command -v curl >/dev/null 2>&1 || apt_install curl >/dev/null 2>&1 || true
  curl -fsSL --max-time 5 https://deb.debian.org >/dev/null 2>&1
}

############################################
# YOUTUBE ZENE (robosztus, logolva)
############################################
MUSIC_PID=""

ensure_music_tools(){
  # Próbáljuk feltenni. Ha fail: log + vissza false.
  if ! command -v yt-dlp >/dev/null 2>&1; then
    apt_install yt-dlp >>"$MUSIC_LOG" 2>&1 || return 1
  fi
  if ! command -v ffplay >/dev/null 2>&1; then
    apt_install ffmpeg >>"$MUSIC_LOG" 2>&1 || return 1
  fi
  return 0
}

music_start(){
  [[ "$ENABLE_MUSIC" != true ]] && return 0

  # ha már megy
  if [[ -n "${MUSIC_PID:-}" ]] && kill -0 "$MUSIC_PID" 2>/dev/null; then
    return 0
  fi

  # előző log fejrész
  {
    echo "============================================================"
    echo "$(date '+%F %T') | MUSIC_START"
    echo "URL: $YOUTUBE_URL"
  } >>"$MUSIC_LOG" 2>&1

  if ! have_internet; then
    warn "Nincs internet – zene kihagyva."
    echo "$(date '+%F %T') | NO_INTERNET" >>"$MUSIC_LOG" 2>&1
    return 1
  fi

  if ! ensure_music_tools; then
    warn "Zene eszközök telepítése nem sikerült (nézd meg: $MUSIC_LOG)."
    echo "$(date '+%F %T') | TOOLS_INSTALL_FAILED" >>"$MUSIC_LOG" 2>&1
    return 1
  fi

  # Indítás: ne nyeljük el a hibát -> MUSIC_LOG-ba megy
  (
    set -o pipefail
    yt-dlp -f bestaudio -o - "$YOUTUBE_URL" 2>>"$MUSIC_LOG" |
      ffplay -nodisp -loglevel error -autoexit -loop 0 -volume "$MUSIC_VOLUME" - 2>>"$MUSIC_LOG"
  ) &

  MUSIC_PID=$!

  # Ellenőrzés: tényleg életben maradt-e
  sleep 0.7
  if kill -0 "$MUSIC_PID" 2>/dev/null; then
    ok "Zene elindult (T=toggle, M=stop)."
    echo "$(date '+%F %T') | MUSIC_OK pid=$MUSIC_PID" >>"$MUSIC_LOG" 2>&1
    return 0
  else
    warn "Zene nem indult el. Nézd meg: $MUSIC_LOG"
    echo "$(date '+%F %T') | MUSIC_FAILED (process exited)" >>"$MUSIC_LOG" 2>&1
    MUSIC_PID=""
    return 1
  fi
}

music_stop(){
  if [[ -n "${MUSIC_PID:-}" ]] && kill -0 "$MUSIC_PID" 2>/dev/null; then
    echo "$(date '+%F %T') | MUSIC_STOP pid=$MUSIC_PID" >>"$MUSIC_LOG" 2>&1
    kill "$MUSIC_PID" 2>/dev/null || true
    sleep 0.2
    kill -9 "$MUSIC_PID" 2>/dev/null || true
    MUSIC_PID=""
  fi
}

music_toggle(){
  if [[ -n "${MUSIC_PID:-}" ]] && kill -0 "$MUSIC_PID" 2>/dev/null; then
    music_stop
  else
    music_start || true
  fi
}

hotkeys(){
  while true; do
    if [[ "${HOTKEYS_PAUSED:-0}" -eq 1 ]]; then
      sleep 0.1
      continue
    fi
    if read -rsn1 -t 0.4 k; then
      case "$k" in
        [Tt]) music_toggle ;;
        [Mm]) music_stop ;;
        [Hh]) echo -e "${BLUE}T=toggle  M=stop  Q=kilépés a BEFEJEZODOTT képernyőről  Log=$LOGFILE  MusicLog=$MUSIC_LOG${NC}" ;;
      esac
    fi
  done
}

############################################
# TELEPÍTŐK + TÖRLÉSEK
############################################
install_apache(){ apt_install apache2 && svc_on apache2; }
remove_apache(){ svc_off apache2; apt_purge apache2 apache2-bin apache2-data apache2-utils || true; apt_autoremove || true; }

install_ssh(){ apt_install openssh-server && svc_on ssh; }
remove_ssh(){ svc_off ssh; apt_purge openssh-server || true; apt_autoremove || true; }

install_mosquitto(){ apt_install mosquitto mosquitto-clients && svc_on mosquitto; }
remove_mosquitto(){ svc_off mosquitto; apt_purge mosquitto mosquitto-clients || true; apt_autoremove || true; }

install_mariadb(){ apt_install mariadb-server && svc_on mariadb; }
remove_mariadb(){ svc_off mariadb; apt_purge mariadb-server || true; apt_autoremove || true; }

install_php(){
  if ! pkg_installed apache2; then
    warn "PHP-hoz kell Apache2."
    ask_yn "Apache2 nincs telepítve. Telepítsem most az Apache2-t?" || { warn "Apache2 nélkül PHP telepítés kihagyva."; return 1; }
    install_apache || return 1
  fi
  apt_install php libapache2-mod-php php-mysql
  systemctl restart apache2 >/dev/null 2>&1 || true
}
remove_php(){
  apt_purge php libapache2-mod-php php-mysql || true
  apt_autoremove || true
  systemctl restart apache2 >/dev/null 2>&1 || true
}

nr_installed(){
  command -v node-red >/dev/null 2>&1 || systemctl list-unit-files | grep -q '^nodered\.service'
}
install_node_red(){
  if nr_installed; then
    ok "Node-RED már telepítve van – nincs teendő."
    systemctl enable --now nodered.service >/dev/null 2>&1 || true
    return 0
  fi

  apt_install curl ca-certificates
  if ! have_internet; then
    warn "Nincs internet – Node-RED nem telepíthető."
    return 1
  fi

  curl -fsSL https://github.com/node-red/linux-installers/releases/latest/download/update-nodejs-and-nodered-deb |
    bash -s -- --confirm-root

  systemctl daemon-reload
  svc_on nodered.service
}
remove_node_red(){
  svc_off nodered.service
  svc_off node-red.service
  apt_purge nodered node-red || true
  apt_autoremove || true
  rm -f /etc/systemd/system/nodered.service /lib/systemd/system/nodered.service 2>/dev/null || true
  systemctl daemon-reload >/dev/null 2>&1 || true
}

install_ufw(){
  apt_install ufw
  ufw allow OpenSSH
  ufw allow 80/tcp
  ufw allow 1880/tcp
  ufw allow 1883/tcp
  ufw --force enable
}
remove_ufw(){
  ufw --force disable >/dev/null 2>&1 || true
  apt_purge ufw || true
  apt_autoremove || true
}

############################################
# FIX STÁTUSZ PANEL (nem mozog)
############################################
STATUS_ROW=1
STATUS_PANEL_HEIGHT=12

draw_status_panel(){
  local row="$1"
  local cols="$2"

  for ((i=0; i<STATUS_PANEL_HEIGHT; i++)); do
    tput cup $((row+i)) 0 2>/dev/null || return
    printf "%*s" "$cols" ""
  done

  tput cup "$row" 0 2>/dev/null || return
  printf "%bÁllapot összegzés:%b\n" "$BOLD" "$NC"

  local comp st
  for comp in "Apache2" "SSH" "Mosquitto" "Node-RED" "MariaDB" "PHP" "UFW"; do
    st="${COMPONENT_STATUS[$comp]:-skipped}"
    case "$st" in
      ok)      printf " %b✔%b %s – kész\n"      "$GREEN" "$NC" "$comp" ;;
      skipped) printf " %b•%b %s – kihagyva\n"   "$YELLOW" "$NC" "$comp" ;;
      removed) printf " %b🗑%b %s – törölve\n"    "$CYAN" "$NC" "$comp" ;;
      error)   printf " %b✖%b %s – hiba\n"       "$RED" "$NC" "$comp" ;;
      *)       printf " %b•%b %s – kihagyva\n"   "$YELLOW" "$NC" "$comp" ;;
    esac
  done
  printf "%bLog:%b %s\n" "$DIM" "$NC" "$LOGFILE"
  printf "%bMusic log:%b %s\n" "$DIM" "$NC" "$MUSIC_LOG"
}

############################################
# BEFEJEZODOTT – mozog, panel fix, végtelen
############################################
befejezodott_spin_color_forever() {
  local -a art=(
"█████   ██████  ██████  ██████    ████  ██████  ██████   ████   █████    ████   ██████  ██████"
"██  ██  ██      ██      ██          ██  ██          ██  ██  ██  ██  ██  ██  ██    ██      ██"
"██  ██  ██      ██      ██          ██  ██         ██   ██  ██  ██  ██  ██  ██    ██      ██"
"█████   █████   █████   █████       ██  █████     ██    ██  ██  ██  ██  ██  ██    ██      ██"
"██  ██  ██      ██      ██      ██  ██  ██       ██     ██  ██  ██  ██  ██  ██    ██      ██"
"██  ██  ██      ██      ██      ██  ██  ██      ██      ██  ██  ██  ██  ██  ██    ██      ██"
"█████   ██████  ██      ██████   ████   ██████  ██████   ████   █████    ████     ██      ██"
  )

  local -a colors=("\e[35m" "\e[34m" "\e[36m" "\e[32m" "\e[33m" "\e[31m")
  local reset="\e[0m"

  local positions=(
    "0 -3" "3 -2" "6 0" "3 2"
    "0 3" "-3 2" "-6 0" "-3 -2"
  )

  if [[ -z "${TERM:-}" || "$TERM" == "dumb" ]]; then
    echo "BEFEJEZODOTT"
    echo "Állapot összegzés:"
    for comp in "Apache2" "SSH" "Mosquitto" "Node-RED" "MariaDB" "PHP" "UFW"; do
      echo " - $comp: ${COMPONENT_STATUS[$comp]:-skipped}"
    done
    echo "(Stahl Dávid Jenő)"
    return 0
  fi

  local rows cols
  rows="$(tput lines 2>/dev/null || echo 24)"
  cols="$(tput cols 2>/dev/null || echo 120)"

  local maxw=0
  for line in "${art[@]}"; do
    (( ${#line} > maxw )) && maxw=${#line}
  done
  local arth=${#art[@]}
  local artw=$maxw

  local base_y=$(( (rows - arth) / 2 ))
  local base_x=$(( (cols - artw) / 2 ))
  (( base_x < 0 )) && base_x=0

  local min_y=$((STATUS_ROW + STATUS_PANEL_HEIGHT + 1))
  (( base_y < min_y )) && base_y=$min_y

  tput civis 2>/dev/null || true

  cleanup_finish(){
    tput cnorm 2>/dev/null || true
    printf "\033[0m\033[2J\033[H"
  }
  trap cleanup_finish INT TERM

  printf "\033[2J\033[H"
  draw_status_panel "$STATUS_ROW" "$cols"

  local frame=0
  local pos_idx=0
  local prev_y=-1
  local prev_x=-1

  while true; do
    if read -rsn1 -t 0.05 k; then
      case "$k" in
        [Qq]) cleanup_finish; return 0 ;;
      esac
    fi

    draw_status_panel "$STATUS_ROW" "$cols"

    local dx dy
    read -r dx dy <<< "${positions[$pos_idx]}"
    pos_idx=$(( (pos_idx + 1) % ${#positions[@]} ))

    local y=$(( base_y + dy ))
    local x=$(( base_x + dx ))

    (( y < min_y )) && y=$min_y
    (( x < 0 )) && x=0
    (( y + arth >= rows-2 )) && y=$(( rows-2-arth ))
    (( x + artw >= cols )) && x=$(( cols-artw ))
    (( y < min_y )) && y=$min_y
    (( x < 0 )) && x=0

    if (( prev_y >= 0 && prev_x >= 0 )); then
      for ((i=0; i<arth; i++)); do
        tput cup $((prev_y+i)) "$prev_x" 2>/dev/null || printf "\033[%d;%dH" "$((prev_y+i+1))" "$((prev_x+1))"
        printf "%*s" "$artw" ""
      done
    fi

    local c="${colors[$((frame % ${#colors[@]}))]}"
    for i in "${!art[@]}"; do
      tput cup $((y+i)) "$x" 2>/dev/null || printf "\033[%d;%dH" "$((y+i+1))" "$((x+1))"
      printf "%b%s%b" "$c" "${art[$i]}" "$reset"
    done

    tput cup $((rows-2)) 0 2>/dev/null || true
    printf "%b(%s)%b  %b[Q]=kilépés  Ctrl+C=kilépés%b" "${PURPLE}" "Stahl Dávid Jenő" "${reset}" "${DIM}" "${reset}"
    printf "\033[K"

    prev_y=$y
    prev_x=$x
    frame=$((frame+1))
    sleep 0.10
  done
}

############################################
# TRAP
############################################
trap 'music_stop 2>/dev/null || true' EXIT

############################################
# FUTTATÁS
############################################
title
hotkeys & HOTKEY_PID=$!

if ask_yn "Indítsak háttérzenét?"; then
  music_start || true
else
  warn "Zene kihagyva."
fi

hr
echo -e "${BOLD}Előkészítés${NC}"
if ask_yn "Futtassak apt-get update-et? (ajánlott)"; then
  ( apt_update ) & pid=$!
  spinner "$pid" "apt-get update fut..."
  wait "$pid" && ok "apt-get update kész" || warn "apt-get update hiba"
else
  warn "apt-get update kihagyva."
fi
echo
hr

run_component(){
  local name="$1" check="$2" install="$3" remove="$4"

  echo -e "${BLUE}${BOLD}==> $name${NC}"

  local is_installed="no"
  if eval "$check"; then
    is_installed="yes"
    echo -e "${DIM}Állapot:${NC} ${GREEN}telepítve${NC}"
  else
    echo -e "${DIM}Állapot:${NC} ${YELLOW}nincs telepítve${NC}"
  fi

  local action=""
  if [[ "$is_installed" == "yes" ]]; then
    action="$(ask_action_installed "Mit csináljak $name komponenssel?")"
  else
    action="$(ask_action_not_installed "Mit csináljak $name komponenssel?")"
  fi

  case "$action" in
    skip)
      warn "$name kihagyva"
      COMPONENT_STATUS["$name"]="skipped"
      echo
      return
      ;;
    install)
      ( eval "$install" ) & pid=$!
      spinner "$pid" "$name fut..."
      if wait "$pid"; then
        ok "$name kész"
        COMPONENT_STATUS["$name"]="ok"
      else
        warn "$name hiba"
        COMPONENT_STATUS["$name"]="error"
      fi
      echo
      return
      ;;
    remove)
      ( eval "$remove" ) & pid=$!
      spinner "$pid" "$name törlése..."
      if wait "$pid"; then
        ok "$name törölve"
        COMPONENT_STATUS["$name"]="removed"
      else
        warn "$name törlés hiba"
        COMPONENT_STATUS["$name"]="error"
      fi
      echo
      return
      ;;
  esac
}

run_component "Apache2"   "pkg_installed apache2"        "install_apache"    "remove_apache"
run_component "SSH"       "pkg_installed openssh-server" "install_ssh"       "remove_ssh"
run_component "Mosquitto" "pkg_installed mosquitto"      "install_mosquitto" "remove_mosquitto"
run_component "Node-RED"  "nr_installed"                 "install_node_red"  "remove_node_red"
run_component "MariaDB"   "pkg_installed mariadb-server" "install_mariadb"   "remove_mariadb"
run_component "PHP"       "(pkg_installed php || pkg_installed libapache2-mod-php)" "install_php" "remove_php"
run_component "UFW"       "pkg_installed ufw"            "install_ufw"       "remove_ufw"

kill "$HOTKEY_PID" 2>/dev/null || true
music_stop

befejezodott_spin_color_forever
