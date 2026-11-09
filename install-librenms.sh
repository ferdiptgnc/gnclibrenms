#!/usr/bin/env bash
#
# ============================================================================
#  install-librenms.sh — Installer LibreNMS (Docker) untuk Debian 13 "trixie"
# ============================================================================
#  Versi  : 1.0.6
#  Target : PC/VM dengan Debian 13 yang baru diinstall (minimal / netinst)
#
#  Cara pakai (sebagai root):
#    wget -qO- https://raw.githubusercontent.com/USER/REPO/main/install-librenms.sh | bash
#    curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/install-librenms.sh | bash
#    bash install-librenms.sh                      # dari file lokal
#
#  Mode tanpa dialog (deploy massal):
#    bash install-librenms.sh --unattended --config client.conf
#    wget -qO- URL | LNMS_ADMIN_PASS='PasswordKuat123' bash -s -- --unattended
#
#  Semua variabel LNMS_* di fungsi set_defaults() bisa di-override lewat
#  environment atau file config (format shell: LNMS_VAR="nilai").
# ============================================================================

set -Eeuo pipefail

readonly SCRIPT_VERSION="1.0.6"
readonly LOG_FILE="/var/log/librenms-install.log"
readonly BACKTITLE="LibreNMS Docker Installer v${SCRIPT_VERSION}  |  Debian 13"

# ---------------------------------------------------------------------------
# Default konfigurasi (semua bisa di-override via env / file config)
# ---------------------------------------------------------------------------
set_defaults() {
  : "${LNMS_UNATTENDED:=0}"              # 1 = tanpa dialog
  : "${LNMS_HOSTNAME:=librenms}"
  : "${LNMS_INSTALL_DIR:=/opt/librenms}"
  : "${LNMS_NET_MODE:=keep}"             # keep (tidak diubah) | static
  : "${LNMS_IFACE:=}"                    # kosong = auto-detect
  : "${LNMS_IP_CIDR:=}"                  # mis. 192.168.1.50/24
  : "${LNMS_GATEWAY:=}"
  : "${LNMS_DNS:=8.8.8.8 1.1.1.1}"
  : "${LNMS_HTTP_PORT:=80}"
  : "${LNMS_PUBLIC_URL:=}"               # mis. https://nms.klien.com (Cloudflare Tunnel/reverse proxy)
  : "${LNMS_TRUSTED_PROXIES:=127.0.0.1,172.16.0.0/12,10.0.0.0/8,192.168.0.0/16}"
  : "${LNMS_TZ:=Asia/Jakarta}"
  : "${LNMS_ADMIN_USER:=admin}"
  : "${LNMS_ADMIN_PASS:=}"               # kosong = di-generate otomatis
  : "${LNMS_ADMIN_EMAIL:=admin@localhost}"
  : "${LNMS_DB_PASS:=}"                  # kosong = di-generate otomatis
  : "${LNMS_SNMP_COMMUNITY:=public}"
  : "${LNMS_ENABLE_SYSLOG:=yes}"         # syslog receiver 514 tcp/udp
  : "${LNMS_ENABLE_TRAP:=yes}"           # snmptrapd 162 tcp/udp
  : "${LNMS_MONITOR_SELF:=yes}"          # install snmpd & tambahkan PC ini
  : "${LNMS_LOCATION:=Kantor Klien}"     # sysLocation untuk snmpd PC ini
  : "${LNMS_ENABLE_SMTP:=no}"
  : "${LNMS_ALLOW_DUP_SYSNAME:=yes}"     # izinkan device dengan sysName sama (mis. banyak switch Ruijie default)
  : "${LNMS_SMTP_HOST:=smtp.gmail.com}"
  : "${LNMS_SMTP_PORT:=587}"
  : "${LNMS_SMTP_USER:=}"
  : "${LNMS_SMTP_PASS:=}"
  : "${LNMS_SMTP_FROM:=}"
  : "${LNMS_MEMORY_LIMIT:=256M}"         # PHP memory_limit
  : "${LNMS_LIBRENMS_TAG:=latest}"       # tag image librenms/librenms
  : "${LNMS_MARIADB_TAG:=10.11}"
  : "${LNMS_REDIS_TAG:=7.2-alpine}"
  : "${LNMS_AUTO_REBOOT:=yes}"           # reboot otomatis bila IP statis butuh reboot
  : "${LNMS_FORCE_OS:=0}"                # 1 = tetap jalan walau bukan Debian 13
  : "${LNMS_BRAND_TAGLINE:=}"            # teks tambahan di bawah logo (opsional)
  : "${LNMS_NO_BANNER:=no}"              # yes = sembunyikan logo
}

# ---------------------------------------------------------------------------
# Utilitas output & logging
# ---------------------------------------------------------------------------
C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YLW=$'\e[33m'; C_CYN=$'\e[36m'; C_BLD=$'\e[1m'; C_RST=$'\e[0m'

_logfile() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" 2>/dev/null || true; }
log()  { printf '%s==>%s %s\n' "$C_CYN" "$C_RST" "$*"; _logfile "INFO  $*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_GRN" "$C_RST" "$*"; _logfile "OK    $*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; _logfile "WARN  $*"; }
die()  {
  printf '%s[GAGAL]%s %s\n' "$C_RED" "$C_RST" "$*" >&2
  _logfile "FAIL  $*"
  [[ -f $LOG_FILE ]] && printf 'Detail lengkap ada di log: %s\n' "$LOG_FILE" >&2
  exit 1
}

# Jalankan perintah, output dicatat ke log. Jangan pakai untuk perintah yang memuat password.
run() {
  _logfile "RUN   $*"
  if ! "$@" >>"$LOG_FILE" 2>&1; then
    printf '%s--- 15 baris terakhir log ---%s\n' "$C_YLW" "$C_RST" >&2
    tail -n 15 "$LOG_FILE" >&2 || true
    die "Perintah gagal: $*"
  fi
}

on_error() { die "Error tak terduga di baris $1: $2"; }
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

is_unattended() { [[ $LNMS_UNATTENDED == 1 ]]; }
is_yes() { [[ ${1,,} =~ ^(1|y|yes|true|on|ya)$ ]]; }

trim() {
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

gen_pass() { # gen_pass <panjang>
  head -c 2048 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-"${1:-20}"
}

# ---------------------------------------------------------------------------
# Banner logo GNC (Galura Nexa Core) — terminal art 256 warna
# ---------------------------------------------------------------------------
GNC_ICON=(
  $'         \e[1;38;5;33m█▀▀▀█\e[0m        \e[1;38;5;137m█▀▀▀█\e[0m        \e[1;38;5;33m█▀▀▀█\e[0m'
  $'         \e[1;38;5;33m█\e[0m   \e[1;38;5;33m█\e[0m        \e[1;38;5;137m█\e[0m   \e[1;38;5;137m█\e[0m        \e[1;38;5;33m█\e[0m   \e[1;38;5;33m█\e[0m'
  $'         \e[1;38;5;33m▀▀▀▀▀▄\e[0m       \e[1;38;5;137m▀▀\e[0m\e[1;38;5;137m\e[48;5;33m▀\e[0m\e[1;38;5;137m▀▀\e[0m       \e[1;38;5;33m▄▀▀▀▀▀\e[0m'
  $'               \e[1;38;5;33m▀▄\e[0m       \e[1;38;5;33m█\e[0m       \e[1;38;5;33m▄▀\e[0m'
  $'                 \e[1;38;5;33m▀▄▄▄▄▄▄█▄▄▄▄▄▄▀\e[0m'
  $'                  \e[1;38;5;33m█\e[0m     \e[1;38;5;33m█\e[0m     \e[1;38;5;33m█\e[0m'
  $'                  \e[1;38;5;33m█\e[0m     \e[1;38;5;33m█\e[0m     \e[1;38;5;33m█\e[0m    \e[1;38;5;137m▄▄▄▄▄\e[0m'
  $'           \e[1;38;5;33m▄▄▄▄▄▄▄█▄▄▄▄▄█▄▄▄▄▄█▄▄▄▄\e[0m\e[1;38;5;137m█\e[0m   \e[1;38;5;137m█\e[0m'
  $'           \e[1;38;5;33m█\e[0m      \e[1;38;5;33m█\e[0m     \e[1;38;5;33m█\e[0m     \e[1;38;5;33m█\e[0m    \e[1;38;5;137m█▄▄▄█\e[0m'
  $'           \e[1;38;5;33m█\e[0m      \e[1;38;5;33m█\e[0m     \e[1;38;5;33m█\e[0m     \e[1;38;5;33m█\e[0m'
  $'           \e[1;38;5;33m█\e[0m      \e[1;38;5;33m█▄▄▄▄▄█▄▄▄▄▄█\e[0m'
  $'           \e[1;38;5;33m█\e[0m            \e[1;38;5;33m█\e[0m      \e[1;38;5;33m▀▄\e[0m'
  $'         \e[1;38;5;137m▄▄\e[0m\e[1;38;5;33m\e[48;5;137m▀\e[0m\e[1;38;5;137m▄▄\e[0m         \e[1;38;5;33m▄█▄\e[0m       \e[1;38;5;33m▀▄▄▄▄▄▄\e[0m'
  $'         \e[1;38;5;137m█\e[0m   \e[1;38;5;137m█\e[0m        \e[1;38;5;33m█\e[0m   \e[1;38;5;33m█\e[0m        \e[1;38;5;33m█\e[0m   \e[1;38;5;33m█\e[0m'
  $'         \e[1;38;5;137m█▄▄▄█\e[0m        \e[1;38;5;33m▀▄▄▄▀\e[0m        \e[1;38;5;33m█▄▄▄█\e[0m'
)
GNC_TEXT=(
  $'  \e[1;38;5;33m██████\e[0m   \e[1;38;5;33m█████\e[0m  \e[1;38;5;33m██\e[0m      \e[1;38;5;33m██\e[0m    \e[1;38;5;33m██\e[0m \e[1;38;5;33m██████\e[0m   \e[1;38;5;33m█████\e[0m'
  $' \e[1;38;5;33m██\e[0m       \e[1;38;5;33m██\e[0m   \e[1;38;5;33m██\e[0m \e[1;38;5;33m██\e[0m      \e[1;38;5;33m██\e[0m    \e[1;38;5;33m██\e[0m \e[1;38;5;33m██\e[0m   \e[1;38;5;33m██\e[0m \e[1;38;5;33m██\e[0m   \e[1;38;5;33m██\e[0m'
  $' \e[1;38;5;33m██\e[0m   \e[1;38;5;33m███\e[0m \e[1;38;5;33m███████\e[0m \e[1;38;5;33m██\e[0m      \e[1;38;5;33m██\e[0m    \e[1;38;5;33m██\e[0m \e[1;38;5;33m██████\e[0m  \e[1;38;5;33m███████\e[0m'
  $' \e[1;38;5;33m██\e[0m    \e[1;38;5;33m██\e[0m \e[1;38;5;33m██\e[0m   \e[1;38;5;33m██\e[0m \e[1;38;5;33m██\e[0m      \e[1;38;5;33m██\e[0m    \e[1;38;5;33m██\e[0m \e[1;38;5;33m██\e[0m   \e[1;38;5;33m██\e[0m \e[1;38;5;33m██\e[0m   \e[1;38;5;33m██\e[0m'
  $'  \e[1;38;5;33m██████\e[0m  \e[1;38;5;33m██\e[0m   \e[1;38;5;33m██\e[0m \e[1;38;5;33m███████\e[0m  \e[1;38;5;33m██████\e[0m  \e[1;38;5;33m██\e[0m   \e[1;38;5;33m██\e[0m \e[1;38;5;33m██\e[0m   \e[1;38;5;33m██\e[0m'
  $''
  $'\e[1;38;5;33m█▄\e[0m  \e[1;38;5;33m█\e[0m \e[1;38;5;33m█▀▀▀\e[0m \e[1;38;5;33m▀▄\e[0m \e[1;38;5;33m▄▀\e[0m \e[1;38;5;33m▄▀▀▀▄\e[0m      \e[1;38;5;33m▄▀▀▀▀\e[0m \e[1;38;5;33m▄▀▀▀▄\e[0m \e[1;38;5;33m█▀▀▀▄\e[0m \e[1;38;5;33m█▀▀▀\e[0m'
  $'\e[1;38;5;33m█\e[0m \e[1;38;5;33m▀▄█\e[0m \e[1;38;5;33m█▀▀\e[0m   \e[1;38;5;33m▄▀▄\e[0m  \e[1;38;5;33m█▀▀▀█\e[0m      \e[1;38;5;33m█\e[0m     \e[1;38;5;33m█\e[0m   \e[1;38;5;33m█\e[0m \e[1;38;5;33m█▀▀█\e[0m  \e[1;38;5;33m█▀▀\e[0m'
  $'\e[1;38;5;33m▀\e[0m   \e[1;38;5;33m▀\e[0m \e[1;38;5;33m▀▀▀▀\e[0m \e[1;38;5;33m▀\e[0m   \e[1;38;5;33m▀\e[0m \e[1;38;5;33m▀\e[0m   \e[1;38;5;33m▀\e[0m       \e[1;38;5;33m▀▀▀▀\e[0m  \e[1;38;5;33m▀▀▀\e[0m  \e[1;38;5;33m▀\e[0m   \e[1;38;5;33m▀\e[0m \e[1;38;5;33m▀▀▀▀\e[0m'
  $''
  $'\e[1;38;5;137mT\e[0m \e[1;38;5;137mE\e[0m \e[1;38;5;137mC\e[0m \e[1;38;5;137mH\e[0m \e[1;38;5;137mN\e[0m \e[1;38;5;137mO\e[0m \e[1;38;5;137mL\e[0m \e[1;38;5;137mO\e[0m \e[1;38;5;137mG\e[0m \e[1;38;5;137mY\e[0m   \e[1;38;5;137mI\e[0m \e[1;38;5;137mN\e[0m \e[1;38;5;137mF\e[0m \e[1;38;5;137mR\e[0m \e[1;38;5;137mA\e[0m \e[1;38;5;137mS\e[0m \e[1;38;5;137mT\e[0m \e[1;38;5;137mR\e[0m \e[1;38;5;137mU\e[0m \e[1;38;5;137mC\e[0m \e[1;38;5;137mT\e[0m \e[1;38;5;137mU\e[0m \e[1;38;5;137mR\e[0m \e[1;38;5;137mE\e[0m'
)

show_banner() {
  is_yes "${LNMS_NO_BANNER:-no}" && return 0
  local rows cols l
  rows=$(tput lines 2>/dev/null || echo 40); cols=$(tput cols 2>/dev/null || echo 80)
  [[ $rows =~ ^[0-9]+$ ]] || rows=40
  [[ $cols =~ ^[0-9]+$ ]] || cols=80
  printf '\n'
  if ((cols >= 54 && rows >= 34)); then
    for l in "${GNC_ICON[@]}"; do printf '  %b\n' "$l"; done   # logo penuh: ikon + teks
    printf '\n'
  fi
  if ((cols >= 54 && rows >= 18)); then
    for l in "${GNC_TEXT[@]}"; do printf '  %b\n' "$l"; done
  else                                                         # terminal kecil: 1 baris
    printf '  \e[1;38;5;33mGALURA NEXA CORE\e[0m  \e[38;5;137mTechnology Infrastructure\e[0m\n'
  fi
  [[ -n ${LNMS_BRAND_TAGLINE:-} ]] && printf '\n  %s%s%s\n' "$C_BLD" "$LNMS_BRAND_TAGLINE" "$C_RST"
  printf '\n  %sLibreNMS Docker Installer v%s  •  Debian 13%s\n' "$C_CYN" "$SCRIPT_VERSION" "$C_RST"
  printf '  %s%s%s\n\n' "$C_CYN" '──────────────────────────────────────────────────' "$C_RST"
}

# ---------------------------------------------------------------------------
# Validator
# ---------------------------------------------------------------------------
valid_ipv4() {
  local ip=$1 o
  [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do ((10#$o <= 255)) || return 1; done
}
valid_cidr() {
  local ip=${1%/*} pfx=${1#*/}
  [[ $1 == */* && $pfx =~ ^[0-9]{1,2}$ ]] && ((pfx >= 1 && pfx <= 32)) && valid_ipv4 "$ip"
}
valid_dns_list() {
  local d; [[ -n $1 ]] || return 1
  for d in $1; do valid_ipv4 "$d" || return 1; done
}
valid_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
valid_hostname() { [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; }
valid_tz() { [[ -n $1 && $1 != *..* && -f /usr/share/zoneinfo/$1 ]]; }
valid_username() { [[ $1 =~ ^[A-Za-z0-9._-]{3,32}$ ]]; }
valid_email() { [[ $1 =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]]; }
valid_community() { [[ $1 =~ ^[A-Za-z0-9._@#%+=:-]{1,64}$ ]]; }
valid_dir() { [[ $1 =~ ^/[A-Za-z0-9._/-]+$ && $1 != "/" ]]; }
valid_safe_pass() { [[ -n $1 && $1 != *"'"* && $1 != *$'\n'* ]]; }
valid_db_pass() { [[ $1 =~ ^[A-Za-z0-9._-]{8,64}$ ]]; }
valid_iface() { [[ -n $1 && -d /sys/class/net/$1 ]]; }
valid_memory() { [[ $1 =~ ^[0-9]+[MG]$ ]]; }
valid_nonempty() { [[ -n $1 ]]; }
valid_public_url() { [[ -z $1 || $1 =~ ^https?://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?/?$ ]]; }
valid_proxy_list() {
  local p; [[ $1 == "*" || $1 == "**" ]] && return 0
  [[ -n $1 ]] || return 1
  for p in ${1//,/ }; do
    valid_ipv4 "${p%/*}" || return 1
    [[ $p != */* ]] || { local pf=${p#*/}; [[ $pf =~ ^[0-9]{1,2}$ ]] && ((pf <= 32)) || return 1; }
  done
}

port_in_use() { # port_in_use <port> [tcp|udp]
  local proto=${2:-tcp} flag=-t
  [[ $proto == udp ]] && flag=-u
  [[ -n $(ss -Hln "$flag" "sport = :$1" 2>/dev/null) ]]
}

# ---------------------------------------------------------------------------
# Helper dialog (whiptail)
# ---------------------------------------------------------------------------
WT_H=12; WT_W=76

user_cancel() {
  is_unattended || clear 2>/dev/null || true
  echo "Instalasi dibatalkan oleh pengguna. LibreNMS belum diinstall."
  exit 1
}

wt_msg() { whiptail --backtitle "$BACKTITLE" --title "$1" --msgbox "$2" "${3:-$WT_H}" "$WT_W" || true; }

# ask_input VAR "Judul" "Teks" "default" [validator] ["pesan error"]
ask_input() {
  local __var=$1 title=$2 text=$3 def=$4 validator=${5:-} err=${6:-"Input tidak valid, silakan ulangi."} out
  while true; do
    out=$(whiptail --backtitle "$BACKTITLE" --title "$title" --inputbox "$text" "$WT_H" "$WT_W" "$def" 3>&1 1>&2 2>&3) || user_cancel
    out=$(trim "$out")
    if [[ -z $validator ]] || "$validator" "$out"; then
      printf -v "$__var" '%s' "$out"
      return 0
    fi
    wt_msg "Input tidak valid" "$err"
    def=$out
  done
}

# ask_password VAR "Judul" minlen allow_empty(yes/no) [validator] ["pesan error"]
ask_password() {
  local __var=$1 title=$2 min=${3:-8} allow_empty=${4:-no} validator=${5:-} err=${6:-} p1 p2 hint=""
  [[ $allow_empty == yes ]] && hint=$'\n\nKosongkan untuk generate password acak otomatis.'
  while true; do
    p1=$(whiptail --backtitle "$BACKTITLE" --title "$title" --passwordbox "Masukkan password (minimal $min karakter).$hint" "$WT_H" "$WT_W" 3>&1 1>&2 2>&3) || user_cancel
    if [[ -z $p1 && $allow_empty == yes ]]; then printf -v "$__var" '%s' ""; return 0; fi
    if ((${#p1} < min)); then wt_msg "Password terlalu pendek" "Password minimal $min karakter."; continue; fi
    if [[ -n $validator ]] && ! "$validator" "$p1"; then wt_msg "Password tidak valid" "$err"; continue; fi
    p2=$(whiptail --backtitle "$BACKTITLE" --title "$title" --passwordbox "Ulangi password:" 10 "$WT_W" 3>&1 1>&2 2>&3) || user_cancel
    if [[ $p1 != "$p2" ]]; then wt_msg "Password tidak sama" "Kedua password tidak sama, silakan ulangi."; continue; fi
    printf -v "$__var" '%s' "$p1"
    return 0
  done
}

onoff() { if is_yes "$1"; then echo ON; else echo OFF; fi; }

# ---------------------------------------------------------------------------
# Argumen
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
install-librenms.sh v${SCRIPT_VERSION} — Installer LibreNMS (Docker) untuk Debian 13

Penggunaan:
  bash install-librenms.sh [opsi]

Opsi:
  -y, --unattended     Tanpa dialog, pakai default + variabel LNMS_* dari env/config
  -c, --config FILE    Baca variabel LNMS_* dari FILE (format shell)
  -h, --help           Tampilkan bantuan ini
  -v, --version        Tampilkan versi

Contoh deploy massal:
  LNMS_ADMIN_PASS='PasswordKuat123' LNMS_HTTP_PORT=80 bash install-librenms.sh -y
EOF
}

parse_args() {
  while (($#)); do
    case $1 in
      -y|--unattended) LNMS_UNATTENDED=1 ;;
      -c|--config)
        [[ -n ${2:-} ]] || die "--config membutuhkan path file."
        LNMS_CONFIG=$2; shift ;;
      -h|--help) usage; exit 0 ;;
      -v|--version) echo "$SCRIPT_VERSION"; exit 0 ;;
      *) die "Opsi tidak dikenal: $1 (lihat --help)" ;;
    esac
    shift
  done
  if [[ -n ${LNMS_CONFIG:-} ]]; then
    [[ -r $LNMS_CONFIG ]] || die "File config tidak bisa dibaca: $LNMS_CONFIG"
    # shellcheck disable=SC1090
    . "$LNMS_CONFIG"
  fi
}

# ---------------------------------------------------------------------------
# Pemeriksaan awal
# ---------------------------------------------------------------------------
preflight() {
  [[ $EUID -eq 0 ]] || die "Jalankan sebagai root (gunakan 'su -' atau 'sudo -i')."
  command -v apt-get >/dev/null 2>&1 || die "Script ini hanya untuk Debian (apt-get tidak ditemukan)."
  mkdir -p "$(dirname "$LOG_FILE")"
  : >>"$LOG_FILE"; chmod 600 "$LOG_FILE"
  _logfile "===== Mulai instalasi v${SCRIPT_VERSION} ====="
  export DEBIAN_FRONTEND=noninteractive
  export LC_ALL=C.UTF-8 2>/dev/null || true
}

# Saat dijalankan via "curl ... | bash", stdin adalah pipe. Sambungkan ke terminal.
attach_tty() {
  is_unattended && return 0
  [[ -t 0 ]] && return 0
  if (: </dev/tty) 2>/dev/null; then
    exec </dev/tty
  else
    die "Tidak ada terminal interaktif. Jalankan langsung 'bash install-librenms.sh' atau gunakan --unattended."
  fi
}

check_internet() {
  log "Memeriksa koneksi internet..."
  getent hosts deb.debian.org >/dev/null 2>&1 || die "DNS/internet tidak tersedia (deb.debian.org tidak bisa di-resolve)."
  getent hosts download.docker.com >/dev/null 2>&1 || warn "download.docker.com tidak bisa di-resolve, nanti dicoba paket Docker dari repo Debian."
  ok "Koneksi internet tersedia"
}

install_prereqs() {
  log "Update daftar paket & install prasyarat (whiptail, curl, dll)..."
  run apt-get update
  run apt-get install -y --no-install-recommends whiptail curl ca-certificates gnupg iproute2 openssl procps
  ok "Prasyarat terpasang"
}

check_os() {
  local id="" ver="" name="unknown"
  if [[ -r /etc/os-release ]]; then
    id=$(. /etc/os-release; echo "${ID:-}")
    ver=$(. /etc/os-release; echo "${VERSION_ID:-}")
    name=$(. /etc/os-release; echo "${PRETTY_NAME:-unknown}")
  fi
  OS_CODENAME=$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-trixie}")
  if [[ $id == debian && $ver == 13 ]]; then
    ok "OS: $name"
    return 0
  fi
  warn "OS terdeteksi: $name. Script ini dirancang untuk Debian 13."
  if is_unattended; then
    [[ $LNMS_FORCE_OS == 1 ]] || die "Set LNMS_FORCE_OS=1 bila tetap ingin melanjutkan."
  else
    whiptail --backtitle "$BACKTITLE" --title "OS tidak sesuai" --defaultno --yesno \
      "OS terdeteksi: $name\n\nScript ini dirancang dan diuji untuk Debian 13 (trixie).\nTetap lanjutkan?" 11 "$WT_W" || user_cancel
  fi
}

detect_system() {
  RAM_MB=$(awk '/^MemTotal/{print int($2/1024)}' /proc/meminfo)
  DISK_FREE_MB=$(df -Pm / | awk 'NR==2{print $4}')
  CPU_CORES=$(nproc 2>/dev/null || echo 1)

  DET_IFACE=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  DET_GW=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')
  DET_IPCIDR=""; DET_DHCP="no"
  if [[ -n $DET_IFACE ]]; then
    DET_IPCIDR=$(ip -4 -o addr show dev "$DET_IFACE" scope global 2>/dev/null | awk '{print $4; exit}')
    if ip -4 -o addr show dev "$DET_IFACE" scope global 2>/dev/null | awk '/dynamic/{f=1} END{exit !f}'; then DET_DHCP="yes"; fi
  fi
  DET_IP=${DET_IPCIDR%/*}

  NET_STACK="unknown"
  if systemctl is-active --quiet NetworkManager 2>/dev/null; then NET_STACK="networkmanager"
  elif systemctl is-active --quiet systemd-networkd 2>/dev/null; then NET_STACK="networkd"
  elif [[ -f /etc/network/interfaces ]] && command -v ifup >/dev/null 2>&1; then NET_STACK="ifupdown"
  fi
  _logfile "System: RAM=${RAM_MB}MB disk_free=${DISK_FREE_MB}MB cpu=${CPU_CORES} iface=${DET_IFACE:-?} ip=${DET_IPCIDR:-?} gw=${DET_GW:-?} dhcp=${DET_DHCP} netstack=${NET_STACK}"
}

resource_warnings() {
  local w=""
  ((RAM_MB < 2000)) && w+="- RAM ${RAM_MB} MB (disarankan minimal 2 GB, ideal 4 GB)\n"
  ((DISK_FREE_MB < 10240)) && w+="- Disk kosong ${DISK_FREE_MB} MB (disarankan minimal 10 GB)\n"
  printf '%b' "$w"
}

# ---------------------------------------------------------------------------
# Pengumpulan konfigurasi — mode dialog
# ---------------------------------------------------------------------------
collect_interactive() {
  local rw choice sel iface_items=() ifc

  rw=$(resource_warnings)
  wt_msg "Selamat datang" \
"Installer ini akan memasang LibreNMS berbasis Docker di PC ini:

  • Docker Engine + Docker Compose (repo resmi Docker)
  • LibreNMS, MariaDB, Redis, dispatcher (poller)
  • Opsional: syslog, SNMP trap, email alert, monitoring PC ini
  • Opsional: konfigurasi IP statis

Terdeteksi: ${CPU_CORES} CPU, ${RAM_MB} MB RAM, disk kosong ${DISK_FREE_MB} MB
Interface  : ${DET_IFACE:-tidak ada} ${DET_IPCIDR:+(${DET_IPCIDR}, $( [[ $DET_DHCP == yes ]] && echo DHCP || echo statis))}
${rw:+$'\nPeringatan:\n'$rw}
Tekan ESC/Cancel di dialog mana pun untuk membatalkan." 22

  ask_input LNMS_HOSTNAME "Hostname" \
    "Hostname PC/server LibreNMS ini.\n(huruf, angka, tanda '-', maks 63 karakter)" \
    "$LNMS_HOSTNAME" valid_hostname "Hostname tidak valid. Gunakan huruf, angka, dan tanda '-'."

  # --- Jaringan ---
  choice=$(whiptail --backtitle "$BACKTITLE" --title "Konfigurasi IP" --default-item "$LNMS_NET_MODE" --menu \
    "IP saat ini: ${DET_IPCIDR:-tidak terdeteksi} di ${DET_IFACE:-?} ($( [[ $DET_DHCP == yes ]] && echo DHCP || echo statis/unknown))\nPilih konfigurasi IP address:" \
    14 "$WT_W" 2 \
    "keep"   "Biarkan seperti sekarang (tidak diubah)" \
    "static" "Set IP statis (disarankan untuk server NMS)" \
    3>&1 1>&2 2>&3) || user_cancel
  LNMS_NET_MODE=$choice

  if [[ $LNMS_NET_MODE == static ]]; then
    for ifc in /sys/class/net/*; do
      ifc=${ifc##*/}
      [[ $ifc == lo || $ifc == docker* || $ifc == br-* || $ifc == veth* ]] && continue
      iface_items+=("$ifc" "$(ip -4 -o addr show dev "$ifc" 2>/dev/null | awk '{print $4; exit}')")
    done
    ((${#iface_items[@]})) || die "Tidak ada interface jaringan yang bisa dikonfigurasi."
    LNMS_IFACE=$(whiptail --backtitle "$BACKTITLE" --title "Interface" --default-item "${LNMS_IFACE:-$DET_IFACE}" --menu \
      "Pilih interface yang akan diberi IP statis:" 15 "$WT_W" 6 "${iface_items[@]}" 3>&1 1>&2 2>&3) || user_cancel
    ask_input LNMS_IP_CIDR "IP Address" "IP address beserta prefix (CIDR).\nContoh: 192.168.1.50/24" \
      "${LNMS_IP_CIDR:-$DET_IPCIDR}" valid_cidr "Format salah. Contoh yang benar: 192.168.1.50/24"
    ask_input LNMS_GATEWAY "Gateway" "Default gateway:" "${LNMS_GATEWAY:-$DET_GW}" valid_ipv4 "Gateway harus IPv4 yang valid."
    ask_input LNMS_DNS "DNS Server" "DNS server (pisahkan dengan spasi):" "$LNMS_DNS" valid_dns_list "Isi satu atau lebih IPv4, dipisah spasi."
  fi

  # --- Port web ---
  while true; do
    ask_input LNMS_HTTP_PORT "Port Web" "Port HTTP untuk Web UI LibreNMS.\n(80 = akses langsung http://IP tanpa menulis port)" \
      "$LNMS_HTTP_PORT" valid_port "Port harus angka 1-65535."
    if port_in_use "$LNMS_HTTP_PORT" tcp; then
      wt_msg "Port dipakai" "Port $LNMS_HTTP_PORT sudah dipakai aplikasi lain. Pilih port lain."
    else break; fi
  done

  # --- Akses publik (Cloudflare Tunnel / reverse proxy) ---
  ask_input LNMS_PUBLIC_URL "Domain Publik (opsional)" \
    "URL publik bila LibreNMS diakses lewat Cloudflare Tunnel / reverse proxy.\nContoh: https://nms.klien.com\n\nKosongkan bila hanya diakses lewat IP lokal." \
    "$LNMS_PUBLIC_URL" valid_public_url "Format salah. Contoh: https://nms.klien.com (tanpa path)"
  LNMS_PUBLIC_URL=${LNMS_PUBLIC_URL%/}
  if [[ -n $LNMS_PUBLIC_URL ]]; then
    ask_input LNMS_TRUSTED_PROXIES "Trusted Proxy" \
      "IP/CIDR reverse proxy yang dipercaya (pisahkan koma).\nDefault mencakup cloudflared di PC ini (Docker) & jaringan LAN privat.\nPersempit ke IP cloudflared bila diketahui, mis. 192.168.1.10" \
      "$LNMS_TRUSTED_PROXIES" valid_proxy_list "Isi IPv4/CIDR dipisah koma, contoh: 127.0.0.1,172.16.0.0/12"
  fi

  # --- Timezone ---
  choice=$(whiptail --backtitle "$BACKTITLE" --title "Zona Waktu" --default-item "$LNMS_TZ" --menu \
    "Pilih zona waktu server:" 15 "$WT_W" 5 \
    "Asia/Jakarta"  "WIB  (UTC+7)" \
    "Asia/Makassar" "WITA (UTC+8)" \
    "Asia/Jayapura" "WIT  (UTC+9)" \
    "UTC"           "UTC" \
    "lainnya"       "Ketik manual (mis. Asia/Singapore)" \
    3>&1 1>&2 2>&3) || user_cancel
  if [[ $choice == lainnya ]]; then
    ask_input LNMS_TZ "Zona Waktu" "Nama zona waktu (format Region/Kota):" "$LNMS_TZ" valid_tz \
      "Zona waktu tidak ditemukan di /usr/share/zoneinfo. Contoh: Asia/Singapore"
  else
    LNMS_TZ=$choice
  fi

  # --- Akun admin ---
  ask_input LNMS_ADMIN_USER "Admin LibreNMS" "Username admin Web UI LibreNMS:" "$LNMS_ADMIN_USER" valid_username \
    "Username 3-32 karakter: huruf, angka, titik, '_' atau '-'."
  ask_password LNMS_ADMIN_PASS "Password Admin" 8 yes
  ask_input LNMS_ADMIN_EMAIL "Email Admin" "Email admin (dipakai juga sebagai sysContact):" "$LNMS_ADMIN_EMAIL" valid_email "Format email tidak valid."

  # --- Database ---
  if whiptail --backtitle "$BACKTITLE" --title "Password Database" --yesno \
     "Generate password database MariaDB secara otomatis?\n\n(Disarankan. Password akan disimpan di file .env dan INSTALL-INFO.txt)" 11 "$WT_W"; then
    LNMS_DB_PASS=""
  else
    ask_password LNMS_DB_PASS "Password Database" 8 no valid_db_pass \
      "Password DB hanya boleh huruf, angka, '.', '_' dan '-' (8-64 karakter)."
  fi

  # --- SNMP ---
  ask_input LNMS_SNMP_COMMUNITY "SNMP Community" \
    "Community SNMP v2c default untuk auto-discovery & penambahan device.\n(Sangat disarankan ganti dari 'public')" \
    "$LNMS_SNMP_COMMUNITY" valid_community "Community hanya huruf, angka, dan simbol ._@#%+=:- (tanpa spasi)."

  # --- Komponen tambahan ---
  sel=$(whiptail --backtitle "$BACKTITLE" --title "Komponen Tambahan" --checklist \
    "Pilih komponen (SPASI = pilih, ENTER = lanjut):" 16 "$WT_W" 5 \
    "syslog" "Syslog receiver (port 514 tcp/udp)"      "$(onoff "$LNMS_ENABLE_SYSLOG")" \
    "trap"   "SNMP trap receiver (port 162 tcp/udp)"   "$(onoff "$LNMS_ENABLE_TRAP")" \
    "self"   "Monitor PC ini sendiri (install snmpd)"  "$(onoff "$LNMS_MONITOR_SELF")" \
    "smtp"   "Kirim email alert via SMTP relay"        "$(onoff "$LNMS_ENABLE_SMTP")" \
    "dupsys" "Izinkan sysName duplikat (Ruijie dll)"   "$(onoff "$LNMS_ALLOW_DUP_SYSNAME")" \
    3>&1 1>&2 2>&3) || user_cancel
  LNMS_ENABLE_SYSLOG=no; LNMS_ENABLE_TRAP=no; LNMS_MONITOR_SELF=no; LNMS_ENABLE_SMTP=no; LNMS_ALLOW_DUP_SYSNAME=no
  [[ $sel == *'"syslog"'* ]] && LNMS_ENABLE_SYSLOG=yes
  [[ $sel == *'"trap"'*   ]] && LNMS_ENABLE_TRAP=yes
  [[ $sel == *'"self"'*   ]] && LNMS_MONITOR_SELF=yes
  [[ $sel == *'"smtp"'*   ]] && LNMS_ENABLE_SMTP=yes
  [[ $sel == *'"dupsys"'* ]] && LNMS_ALLOW_DUP_SYSNAME=yes

  if is_yes "$LNMS_MONITOR_SELF"; then
    ask_input LNMS_LOCATION "Lokasi" "Lokasi PC ini (sysLocation SNMP):" "$LNMS_LOCATION" valid_nonempty "Lokasi tidak boleh kosong."
  fi

  if is_yes "$LNMS_ENABLE_SMTP"; then
    ask_input LNMS_SMTP_HOST "SMTP" "SMTP server:" "$LNMS_SMTP_HOST" valid_hostname_or_ip "Host SMTP tidak valid."
    ask_input LNMS_SMTP_PORT "SMTP" "Port SMTP (587 = STARTTLS, 465 = SSL/TLS):" "$LNMS_SMTP_PORT" valid_port "Port harus angka 1-65535."
    ask_input LNMS_SMTP_USER "SMTP" "Username SMTP (biasanya alamat email):" "$LNMS_SMTP_USER" valid_nonempty "Username SMTP tidak boleh kosong."
    ask_password LNMS_SMTP_PASS "Password SMTP" 1 no valid_safe_pass "Password SMTP tidak boleh mengandung tanda kutip tunggal (')."
    ask_input LNMS_SMTP_FROM "SMTP" "Alamat pengirim (From):" "${LNMS_SMTP_FROM:-$LNMS_SMTP_USER}" valid_email "Format email tidak valid."
  fi

  # --- Lain-lain ---
  ask_input LNMS_INSTALL_DIR "Folder Instalasi" "Folder untuk file compose & data LibreNMS:" "$LNMS_INSTALL_DIR" valid_dir \
    "Path harus absolut, contoh: /opt/librenms"
  ask_input LNMS_MEMORY_LIMIT "PHP Memory Limit" "Memory limit PHP LibreNMS (mis. 256M, 512M, 1G):" "$LNMS_MEMORY_LIMIT" valid_memory \
    "Format: angka diikuti M atau G, contoh 512M"
}

valid_hostname_or_ip() { valid_ipv4 "$1" || [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]]; }

# ---------------------------------------------------------------------------
# Pengumpulan konfigurasi — mode tanpa dialog
# ---------------------------------------------------------------------------
collect_unattended() {
  log "Mode unattended: memakai default + variabel LNMS_*"
  valid_hostname "$LNMS_HOSTNAME"       || die "LNMS_HOSTNAME tidak valid: $LNMS_HOSTNAME"
  valid_dir "$LNMS_INSTALL_DIR"         || die "LNMS_INSTALL_DIR tidak valid: $LNMS_INSTALL_DIR"
  valid_port "$LNMS_HTTP_PORT"          || die "LNMS_HTTP_PORT tidak valid: $LNMS_HTTP_PORT"
  port_in_use "$LNMS_HTTP_PORT" tcp     && die "Port $LNMS_HTTP_PORT sudah dipakai aplikasi lain."
  valid_tz "$LNMS_TZ"                   || die "LNMS_TZ tidak ditemukan: $LNMS_TZ"
  valid_username "$LNMS_ADMIN_USER"     || die "LNMS_ADMIN_USER tidak valid: $LNMS_ADMIN_USER"
  [[ -z $LNMS_ADMIN_PASS || ${#LNMS_ADMIN_PASS} -ge 8 ]] || die "LNMS_ADMIN_PASS minimal 8 karakter."
  valid_email "$LNMS_ADMIN_EMAIL"       || die "LNMS_ADMIN_EMAIL tidak valid: $LNMS_ADMIN_EMAIL"
  [[ -z $LNMS_DB_PASS ]] || valid_db_pass "$LNMS_DB_PASS" || die "LNMS_DB_PASS hanya huruf/angka/._- (8-64)."
  valid_community "$LNMS_SNMP_COMMUNITY" || die "LNMS_SNMP_COMMUNITY tidak valid."
  valid_memory "$LNMS_MEMORY_LIMIT"     || die "LNMS_MEMORY_LIMIT tidak valid (contoh 256M)."
  valid_public_url "$LNMS_PUBLIC_URL"   || die "LNMS_PUBLIC_URL tidak valid (contoh https://nms.klien.com)."
  LNMS_PUBLIC_URL=${LNMS_PUBLIC_URL%/}
  valid_proxy_list "$LNMS_TRUSTED_PROXIES" || die "LNMS_TRUSTED_PROXIES tidak valid (IPv4/CIDR dipisah koma)."
  case $LNMS_NET_MODE in
    keep) ;;
    static)
      LNMS_IFACE=${LNMS_IFACE:-$DET_IFACE}
      valid_iface "$LNMS_IFACE"      || die "LNMS_IFACE tidak ditemukan: ${LNMS_IFACE:-kosong}"
      valid_cidr "$LNMS_IP_CIDR"     || die "LNMS_IP_CIDR wajib & harus format CIDR (mis. 192.168.1.50/24)."
      valid_ipv4 "$LNMS_GATEWAY"     || die "LNMS_GATEWAY wajib & harus IPv4."
      valid_dns_list "$LNMS_DNS"     || die "LNMS_DNS tidak valid."
      ;;
    *) die "LNMS_NET_MODE harus 'keep' atau 'static'." ;;
  esac
  if is_yes "$LNMS_ENABLE_SMTP"; then
    [[ -n $LNMS_SMTP_HOST && -n $LNMS_SMTP_USER ]] || die "SMTP aktif: LNMS_SMTP_HOST & LNMS_SMTP_USER wajib diisi."
    valid_port "$LNMS_SMTP_PORT"     || die "LNMS_SMTP_PORT tidak valid."
    valid_safe_pass "$LNMS_SMTP_PASS" || die "LNMS_SMTP_PASS wajib & tidak boleh mengandung tanda kutip tunggal."
    LNMS_SMTP_FROM=${LNMS_SMTP_FROM:-$LNMS_SMTP_USER}
  fi
}

# ---------------------------------------------------------------------------
# Finalisasi nilai & konfirmasi
# ---------------------------------------------------------------------------
finalize_config() {
  ADMIN_PASS_GENERATED=no
  if [[ -z $LNMS_ADMIN_PASS ]]; then LNMS_ADMIN_PASS=$(gen_pass 16); ADMIN_PASS_GENERATED=yes; fi
  [[ -n $LNMS_DB_PASS ]] || LNMS_DB_PASS=$(gen_pass 24)

  if [[ $LNMS_NET_MODE == static ]]; then FINAL_IP=${LNMS_IP_CIDR%/*}; else FINAL_IP=${DET_IP:-127.0.0.1}; fi
  if [[ $LNMS_HTTP_PORT == 80 ]]; then WEB_URL="http://${FINAL_IP}"; else WEB_URL="http://${FINAL_IP}:${LNMS_HTTP_PORT}"; fi

  IP_CHANGES=no
  [[ $LNMS_NET_MODE == static && $FINAL_IP != "${DET_IP:-}" ]] && IP_CHANGES=yes

  # Cek port tambahan
  if is_yes "$LNMS_ENABLE_SYSLOG" && { port_in_use 514 tcp || port_in_use 514 udp; }; then
    warn "Port 514 sudah dipakai (mungkin rsyslog). Syslog receiver dinonaktifkan."; LNMS_ENABLE_SYSLOG=no
  fi
  if is_yes "$LNMS_ENABLE_TRAP" && { port_in_use 162 tcp || port_in_use 162 udp; }; then
    warn "Port 162 sudah dipakai. SNMP trap receiver dinonaktifkan."; LNMS_ENABLE_TRAP=no
  fi

  if [[ -e $LNMS_INSTALL_DIR/compose.yml || -d $LNMS_INSTALL_DIR/db ]]; then
    die "Folder $LNMS_INSTALL_DIR sudah berisi instalasi LibreNMS.
       Pilih folder lain (LNMS_INSTALL_DIR) atau hapus dulu instalasi lama:
       cd $LNMS_INSTALL_DIR && docker compose down && cd / && rm -rf $LNMS_INSTALL_DIR"
  fi
}

confirm_config() {
  local net_txt smtp_txt ssh_warn=""
  if [[ $LNMS_NET_MODE == static ]]; then
    net_txt="Statis $LNMS_IP_CIDR via $LNMS_GATEWAY di $LNMS_IFACE\n  DNS            : $LNMS_DNS"
  else
    net_txt="Tidak diubah (${DET_IPCIDR:-?} di ${DET_IFACE:-?})"
  fi
  if is_yes "$LNMS_ENABLE_SMTP"; then smtp_txt="Ya ($LNMS_SMTP_HOST:$LNMS_SMTP_PORT)"; else smtp_txt="Tidak"; fi
  if [[ $IP_CHANGES == yes && -n ${SSH_CONNECTION:-} ]]; then
    ssh_warn="\n\nPERHATIAN: Anda terhubung via SSH. IP akan berubah ke $FINAL_IP di akhir\ninstalasi, sesi SSH ini akan terputus."
  fi

  local summary
  summary="Hostname       : $LNMS_HOSTNAME
  Jaringan       : $net_txt
  URL Web UI     : $WEB_URL
  URL publik     : ${LNMS_PUBLIC_URL:-tidak ada}
  Zona waktu     : $LNMS_TZ
  Admin          : $LNMS_ADMIN_USER ($LNMS_ADMIN_EMAIL)
  Password admin : $( [[ $ADMIN_PASS_GENERATED == yes ]] && echo 'di-generate otomatis (ditampilkan di akhir)' || echo '******** (sesuai input)')
  SNMP community : $LNMS_SNMP_COMMUNITY
  Syslog (514)   : $LNMS_ENABLE_SYSLOG
  SNMP trap (162): $LNMS_ENABLE_TRAP
  Monitor PC ini : $LNMS_MONITOR_SELF
  Email alert    : $smtp_txt
  sysName dobel  : $LNMS_ALLOW_DUP_SYSNAME
  Folder         : $LNMS_INSTALL_DIR
  PHP memory     : $LNMS_MEMORY_LIMIT"

  if is_unattended; then
    log "Ringkasan konfigurasi:"; printf '  %b\n' "$summary"
    return 0
  fi
  whiptail --backtitle "$BACKTITLE" --title "Konfirmasi" --scrolltext --yesno \
    "Periksa konfigurasi berikut:\n\n  ${summary}${ssh_warn}\n\nLanjutkan instalasi?" 26 "$WT_W" || user_cancel
}

# ---------------------------------------------------------------------------
# Instalasi sistem
# ---------------------------------------------------------------------------
set_hostname_tz() {
  if [[ $(hostname) != "$LNMS_HOSTNAME" ]]; then
    log "Set hostname: $LNMS_HOSTNAME"
    hostnamectl set-hostname "$LNMS_HOSTNAME" >>"$LOG_FILE" 2>&1 || { echo "$LNMS_HOSTNAME" >/etc/hostname; hostname "$LNMS_HOSTNAME"; }
    if grep -q '^127\.0\.1\.1' /etc/hosts; then
      sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${LNMS_HOSTNAME}/" /etc/hosts
    else
      printf '127.0.1.1\t%s\n' "$LNMS_HOSTNAME" >>/etc/hosts
    fi
  fi
  log "Set zona waktu sistem: $LNMS_TZ"
  timedatectl set-timezone "$LNMS_TZ" >>"$LOG_FILE" 2>&1 || { ln -sf "/usr/share/zoneinfo/$LNMS_TZ" /etc/localtime; echo "$LNMS_TZ" >/etc/timezone; }
  timedatectl set-ntp true >>"$LOG_FILE" 2>&1 || true
  ok "Hostname & zona waktu diset"
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    ok "Docker sudah terpasang: $(docker --version)"
  else
    log "Menginstall Docker Engine dari repo resmi Docker (beberapa menit)..."
    local official_ok=no
    install -m 0755 -d /etc/apt/keyrings
    if curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc >>"$LOG_FILE" 2>&1; then
      chmod a+r /etc/apt/keyrings/docker.asc
      cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${OS_CODENAME}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
      if apt-get update >>"$LOG_FILE" 2>&1 && \
         apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >>"$LOG_FILE" 2>&1; then
        official_ok=yes
      fi
    fi
    if [[ $official_ok != yes ]]; then
      warn "Repo resmi Docker gagal, memakai paket docker.io dari repo Debian."
      rm -f /etc/apt/sources.list.d/docker.sources
      run apt-get update
      run apt-get install -y docker.io docker-compose
    fi
    ok "Docker terpasang: $(docker --version)"
  fi

  if [[ ! -f /etc/docker/daemon.json ]]; then
    mkdir -p /etc/docker
    cat >/etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
  fi
  run systemctl enable docker
  run systemctl restart docker

  if docker compose version >/dev/null 2>&1; then COMPOSE=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then COMPOSE=(docker-compose)
  else die "Docker Compose tidak ditemukan setelah instalasi."; fi
  ok "Compose: $("${COMPOSE[@]}" version 2>/dev/null | head -n1)"
}

write_compose_files() {
  local d=$LNMS_INSTALL_DIR puid pgid depends svc_extra=""
  log "Menulis konfigurasi ke $d"

  if ! id -u librenms >/dev/null 2>&1; then
    run useradd --system --no-create-home --home-dir "$d" --shell /usr/sbin/nologin librenms
  fi
  puid=$(id -u librenms); pgid=$(id -g librenms)

  mkdir -p "$d"/{db,librenms}
  chmod 750 "$d"

  # .env — variabel interpolasi compose (nilai aman: tanpa spasi/kutip)
  cat >"$d/.env" <<EOF
# Dibuat oleh install-librenms.sh v${SCRIPT_VERSION} pada $(date '+%F %T')
TZ=${LNMS_TZ}
PUID=${puid}
PGID=${pgid}
HTTP_PORT=${LNMS_HTTP_PORT}
LIBRENMS_TAG=${LNMS_LIBRENMS_TAG}
MARIADB_TAG=${LNMS_MARIADB_TAG}
REDIS_TAG=${LNMS_REDIS_TAG}
MYSQL_DATABASE=librenms
MYSQL_USER=librenms
MYSQL_PASSWORD=${LNMS_DB_PASS}
EOF

  cat >"$d/librenms.env" <<EOF
MEMORY_LIMIT=${LNMS_MEMORY_LIMIT}
MAX_INPUT_VARS=1000
UPLOAD_MAX_SIZE=16M
OPCACHE_MEM_SIZE=128
REAL_IP_FROM=0.0.0.0/32
REAL_IP_HEADER=X-Forwarded-For
LOG_IP_VAR=remote_addr

CACHE_DRIVER=redis
SESSION_DRIVER=redis
REDIS_HOST=redis

LIBRENMS_WEATHERMAP=false

# Reverse proxy (Cloudflare Tunnel dll). LibreNMS >= 26.5 tidak lagi mempercayai
# header X-Forwarded-* secara default -> tanpa ini muncul error "Mixed Content".
APP_TRUSTED_PROXIES=${LNMS_TRUSTED_PROXIES}
EOF
  [[ -n $LNMS_PUBLIC_URL ]] && echo "LIBRENMS_BASE_URL=${LNMS_PUBLIC_URL}/" >>"$d/librenms.env"

  depends="      - db
      - redis"

  if is_yes "$LNMS_ENABLE_SMTP"; then
    local starttls=on
    [[ $LNMS_SMTP_PORT == 465 ]] && starttls=off
    cat >"$d/msmtpd.env" <<EOF
SMTP_HOST=${LNMS_SMTP_HOST}
SMTP_PORT=${LNMS_SMTP_PORT}
SMTP_TLS=on
SMTP_STARTTLS=${starttls}
SMTP_TLS_CHECKCERT=on
SMTP_AUTH=on
SMTP_USER=${LNMS_SMTP_USER}
SMTP_PASSWORD='${LNMS_SMTP_PASS}'
SMTP_FROM=${LNMS_SMTP_FROM}
EOF
    depends+="
      - msmtpd"
    svc_extra+="
  msmtpd:
    image: crazymax/msmtpd:latest
    container_name: librenms_msmtpd
    env_file:
      - \"./msmtpd.env\"
    restart: always
"
  fi

  if is_yes "$LNMS_ENABLE_SYSLOG"; then
    svc_extra+="
  syslogng:
    <<: *librenms-common
    container_name: librenms_syslogng
    hostname: librenms-syslogng
    depends_on:
      - librenms
      - redis
    ports:
      - target: 514
        published: 514
        protocol: tcp
      - target: 514
        published: 514
        protocol: udp
    environment:
      <<: *librenms-env
      SIDECAR_SYSLOGNG: \"1\"
"
  fi

  if is_yes "$LNMS_ENABLE_TRAP"; then
    svc_extra+="
  snmptrapd:
    <<: *librenms-common
    container_name: librenms_snmptrapd
    hostname: librenms-snmptrapd
    depends_on:
      - librenms
      - redis
    ports:
      - target: 162
        published: 162
        protocol: tcp
      - target: 162
        published: 162
        protocol: udp
    environment:
      <<: *librenms-env
      SIDECAR_SNMPTRAPD: \"1\"
"
  fi

  cat >"$d/compose.yml" <<EOF
# Dibuat oleh install-librenms.sh v${SCRIPT_VERSION}
# Ubah nilai di file .env lalu jalankan: docker compose up -d
name: librenms

x-librenms-env: &librenms-env
  TZ: \${TZ}
  PUID: \${PUID}
  PGID: \${PGID}
  DB_HOST: db
  DB_NAME: \${MYSQL_DATABASE}
  DB_USER: \${MYSQL_USER}
  DB_PASSWORD: \${MYSQL_PASSWORD}
  DB_TIMEOUT: "60"

x-librenms-common: &librenms-common
  image: librenms/librenms:\${LIBRENMS_TAG}
  cap_add:
    - NET_ADMIN
    - NET_RAW
  volumes:
    - "./librenms:/data"
  env_file:
    - "./librenms.env"
  restart: always

services:
  db:
    image: mariadb:\${MARIADB_TAG}
    container_name: librenms_db
    command:
      - "mysqld"
      - "--innodb-file-per-table=1"
      - "--lower-case-table-names=0"
      - "--character-set-server=utf8mb4"
      - "--collation-server=utf8mb4_unicode_ci"
    volumes:
      - "./db:/var/lib/mysql"
    environment:
      TZ: \${TZ}
      MARIADB_RANDOM_ROOT_PASSWORD: "yes"
      MYSQL_DATABASE: \${MYSQL_DATABASE}
      MYSQL_USER: \${MYSQL_USER}
      MYSQL_PASSWORD: \${MYSQL_PASSWORD}
    restart: always

  redis:
    image: redis:\${REDIS_TAG}
    container_name: librenms_redis
    environment:
      TZ: \${TZ}
    restart: always

  librenms:
    <<: *librenms-common
    container_name: librenms
    hostname: librenms
    depends_on:
${depends}
    ports:
      - target: 8000
        published: \${HTTP_PORT}
        protocol: tcp
    environment:
      <<: *librenms-env

  dispatcher:
    <<: *librenms-common
    container_name: librenms_dispatcher
    hostname: librenms-dispatcher
    depends_on:
      - librenms
      - redis
    environment:
      <<: *librenms-env
      DISPATCHER_NODE_ID: dispatcher1
      SIDECAR_DISPATCHER: "1"
${svc_extra}
EOF

  chmod 600 "$d/.env" "$d/librenms.env"
  [[ -f $d/msmtpd.env ]] && chmod 600 "$d/msmtpd.env"

  "${COMPOSE[@]}" -f "$d/compose.yml" config -q >>"$LOG_FILE" 2>&1 || die "compose.yml tidak valid, cek $LOG_FILE"
  ok "File compose ditulis & tervalidasi"
}

start_stack() {
  local cf=$LNMS_INSTALL_DIR/compose.yml
  log "Download image Docker (tergantung kecepatan internet)..."
  _logfile "RUN   ${COMPOSE[*]} -f $cf pull"
  if ! "${COMPOSE[@]}" -f "$cf" pull; then
    die "Gagal download image Docker. Cek koneksi internet lalu jalankan ulang."
  fi
  # Tahap 1: hanya container inti. Migrasi DB dijalankan oleh container 'librenms';
  # dispatcher & sidecar baru dinyalakan setelah web siap agar tidak query tabel yang belum ada.
  local core=(db redis librenms)
  is_yes "$LNMS_ENABLE_SMTP" && core+=(msmtpd)
  log "Menjalankan container inti (${core[*]})..."
  run "${COMPOSE[@]}" -f "$cf" up -d --no-deps "${core[@]}"
  ok "Container inti berjalan"
}

# Menyiapkan .env LibreNMS di volume data:
#  - hapus penanda INSTALL= (admin sudah dibuat via CLI) agar wizard /install tidak muncul
#  - pastikan APP_TRUSTED_PROXIES ada, apa pun versi image Docker-nya
finalize_install() {
  local envf=$LNMS_INSTALL_DIR/librenms/.env cf=$LNMS_INSTALL_DIR/compose.yml loc changed=no
  if [[ -f $envf ]]; then
    cp -p "$envf" "$envf.bak"
    if [[ ${ADMIN_FAILED:-no} != yes ]] && grep -q '^INSTALL=' "$envf"; then
      sed -i '/^INSTALL=/d' "$envf"; changed=yes
    fi
    if ! grep -qxF "APP_TRUSTED_PROXIES=${LNMS_TRUSTED_PROXIES}" "$envf"; then
      sed -i '/^APP_TRUSTED_PROXIES=/d' "$envf"
      echo "APP_TRUSTED_PROXIES=${LNMS_TRUSTED_PROXIES}" >>"$envf"; changed=yes
    fi
    chown --reference="$envf.bak" "$envf"; chmod --reference="$envf.bak" "$envf"
  else
    warn "File $envf belum ada, lewati penyesuaian .env"
  fi
  if [[ $changed == yes ]]; then
    log "Menerapkan konfigurasi .env (wizard dilewati, trusted proxy diset)..."
    run "${COMPOSE[@]}" -f "$cf" restart librenms
    wait_ready
  fi
  loc=$(curl -s -o /dev/null -m 5 -w '%{redirect_url}' "http://127.0.0.1:${LNMS_HTTP_PORT}/login" 2>/dev/null || true)
  if [[ $loc == */install* ]]; then
    warn "Web UI masih mengarah ke wizard /install. Cek: grep INSTALL $envf"
    WIZARD_PENDING=yes
  else
    ok "Web UI siap login tanpa wizard"
  fi
  check_proxy_https
}

# Simulasikan request dari Cloudflare: halaman harus memakai https, bukan http
check_proxy_https() {
  [[ -n $LNMS_PUBLIC_URL ]] || return 0
  local host=${LNMS_PUBLIC_URL#*://}; host=${host%%/*}
  if curl -s -m 10 -H "Host: $host" -H "X-Forwarded-Proto: https" -H "X-Forwarded-Host: $host" \
       "http://127.0.0.1:${LNMS_HTTP_PORT}/login" 2>/dev/null | grep -q "http://${host}"; then
    warn "Halaman masih memuat URL http:// untuk $host — cek APP_TRUSTED_PROXIES."
  else
    ok "Akses via $LNMS_PUBLIC_URL siap (tanpa Mixed Content)"
  fi
}

start_workers() {
  local cf=$LNMS_INSTALL_DIR/compose.yml
  log "Menjalankan dispatcher & sidecar..."
  run "${COMPOSE[@]}" -f "$cf" up -d
  ok "Semua container berjalan"
}

wait_ready() {
  local i code
  log "Menunggu LibreNMS siap (inisialisasi database, maks ±6 menit)..."
  for ((i = 1; i <= 120; i++)); do
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:${LNMS_HTTP_PORT}/login" 2>/dev/null || true)
    if [[ $code == 200 || $code == 302 ]]; then
      printf '\n'; ok "Web UI merespons (HTTP $code)"; return 0
    fi
    printf '.'; sleep 3
  done
  printf '\n'
  die "LibreNMS belum siap setelah 6 menit. Cek: cd $LNMS_INSTALL_DIR && docker compose logs librenms"
}

lnms() { docker exec --user librenms librenms lnms "$@"; }

create_admin() {
  local i
  log "Membuat user admin '$LNMS_ADMIN_USER'..."
  for ((i = 1; i <= 6; i++)); do
    # Password sengaja tidak lewat run() agar tidak tercatat di log
    if lnms user:add --role=admin --email="$LNMS_ADMIN_EMAIL" --password="$LNMS_ADMIN_PASS" "$LNMS_ADMIN_USER" >>"$LOG_FILE" 2>&1; then
      ok "User admin dibuat"; return 0
    fi
    sleep 10
  done
  warn "Gagal membuat user admin otomatis. Buat manual dengan:
       docker exec -it --user librenms librenms lnms user:add --role=admin $LNMS_ADMIN_USER"
  ADMIN_FAILED=yes
}

configure_librenms() {
  if [[ -n $LNMS_PUBLIC_URL ]]; then
    if lnms config:set base_url "${LNMS_PUBLIC_URL}/" >>"$LOG_FILE" 2>&1; then ok "base_url diset ke ${LNMS_PUBLIC_URL}/"
    else warn "Gagal set base_url: lnms config:set base_url ${LNMS_PUBLIC_URL}/"; fi
  fi
  log "Set SNMP community default: $LNMS_SNMP_COMMUNITY"
  if lnms config:set snmp.community "[\"${LNMS_SNMP_COMMUNITY}\"]" >>"$LOG_FILE" 2>&1; then
    ok "SNMP community default diset"
  else
    warn "Gagal set community default, atur manual di Settings > Poller > SNMP"
  fi

  if is_yes "$LNMS_ALLOW_DUP_SYSNAME"; then
    if lnms config:set allow_duplicate_sysName true >>"$LOG_FILE" 2>&1; then ok "sysName duplikat diizinkan"
    else warn "Gagal set allow_duplicate_sysName: jalankan 'lnms config:set allow_duplicate_sysName true'"; fi
  fi

  if is_yes "$LNMS_ENABLE_SYSLOG"; then
    if lnms config:set enable_syslog true >>"$LOG_FILE" 2>&1; then ok "Pemrosesan syslog diaktifkan"
    else warn "Gagal mengaktifkan syslog: jalankan 'lnms config:set enable_syslog true'"; fi
  fi

  if is_yes "$LNMS_ENABLE_SMTP"; then
    log "Konfigurasi email alert via msmtpd..."
    {
      lnms config:set email_backend smtp
      lnms config:set email_smtp_host msmtpd
      lnms config:set email_smtp_port 2500
      lnms config:set email_smtp_auth false
      lnms config:set email_from "$LNMS_SMTP_FROM"
    } >>"$LOG_FILE" 2>&1 && ok "Email alert dikonfigurasi" || warn "Sebagian konfigurasi email gagal, atur manual di Settings > Alerting > Email"
  fi
}

setup_self_monitoring() {
  is_yes "$LNMS_MONITOR_SELF" || return 0
  log "Install & konfigurasi snmpd untuk monitoring PC ini..."
  run apt-get install -y --no-install-recommends snmpd
  [[ -f /etc/snmp/snmpd.conf && ! -f /etc/snmp/snmpd.conf.orig ]] && cp /etc/snmp/snmpd.conf /etc/snmp/snmpd.conf.orig
  cat >/etc/snmp/snmpd.conf <<EOF
# Dibuat oleh install-librenms.sh — asli: /etc/snmp/snmpd.conf.orig
agentaddress  udp:161
sysLocation   ${LNMS_LOCATION}
sysContact    ${LNMS_ADMIN_EMAIL}
# Hanya localhost & jaringan Docker (container LibreNMS) yang boleh membaca
rocommunity   ${LNMS_SNMP_COMMUNITY} 127.0.0.1
rocommunity   ${LNMS_SNMP_COMMUNITY} 172.16.0.0/12
rocommunity   ${LNMS_SNMP_COMMUNITY} 192.168.0.0/16
includeDir    /etc/snmp/snmpd.conf.d
EOF
  mkdir -p /etc/snmp/snmpd.conf.d
  run systemctl enable snmpd
  run systemctl restart snmpd

  local args=(--v2c -c "$LNMS_SNMP_COMMUNITY")
  [[ $IP_CHANGES == yes ]] && args+=(--force)  # IP baru belum aktif, lewati cek SNMP
  if lnms device:add "${args[@]}" "$FINAL_IP" >>"$LOG_FILE" 2>&1; then
    ok "PC ini ($FINAL_IP) ditambahkan sebagai device"
  else
    warn "Gagal menambahkan PC ini sebagai device. Tambah manual: lnms device:add --v2c -c $LNMS_SNMP_COMMUNITY $FINAL_IP"
  fi
}

open_firewall() {
  command -v ufw >/dev/null 2>&1 || return 0
  ufw status 2>/dev/null | grep -q 'Status: active' || return 0
  log "UFW aktif, membuka port yang diperlukan..."
  run ufw allow "${LNMS_HTTP_PORT}/tcp"
  if is_yes "$LNMS_ENABLE_SYSLOG"; then run ufw allow 514/tcp; run ufw allow 514/udp; fi
  if is_yes "$LNMS_ENABLE_TRAP"; then run ufw allow 162/tcp; run ufw allow 162/udp; fi
}

write_info_file() {
  local f=$LNMS_INSTALL_DIR/INSTALL-INFO.txt
  {
    echo "LibreNMS — info instalasi ($(date '+%F %T'))"
    echo "Installer        : install-librenms.sh v${SCRIPT_VERSION}"
    echo "Hostname         : $LNMS_HOSTNAME"
    echo "URL Web UI       : $WEB_URL"
    [[ -n $LNMS_PUBLIC_URL ]] && echo "URL publik       : $LNMS_PUBLIC_URL"
    echo "Trusted proxies  : $LNMS_TRUSTED_PROXIES"
    echo "Admin username   : $LNMS_ADMIN_USER"
    if [[ $ADMIN_PASS_GENERATED == yes ]]; then
      echo "Admin password   : $LNMS_ADMIN_PASS   (di-generate, segera ganti setelah login)"
    else
      echo "Admin password   : (sesuai yang diinput saat instalasi)"
    fi
    echo "DB user/password : librenms / $LNMS_DB_PASS"
    echo "SNMP community   : $LNMS_SNMP_COMMUNITY"
    echo "Zona waktu       : $LNMS_TZ"
    echo "Folder           : $LNMS_INSTALL_DIR"
    echo
    echo "Perintah berguna:"
    echo "  cd $LNMS_INSTALL_DIR"
    echo "  docker compose ps                    # status container"
    echo "  docker compose logs -f librenms      # log"
    echo "  docker compose pull && docker compose up -d   # update"
    echo "  docker exec --user librenms librenms php validate.php"
    echo "  docker exec -it --user librenms librenms lnms user:password $LNMS_ADMIN_USER"
  } >"$f"
  chmod 600 "$f"
}

# ---------------------------------------------------------------------------
# IP statis (diterapkan paling akhir)
# ---------------------------------------------------------------------------
apply_static_network() {
  [[ $LNMS_NET_MODE == static ]] || return 0
  NET_APPLY="none"
  local dns_csv=${LNMS_DNS// /,} d
  log "Menyiapkan IP statis $LNMS_IP_CIDR di $LNMS_IFACE (stack: $NET_STACK)"

  case $NET_STACK in
    networkmanager)
      local con
      con=$(nmcli -g GENERAL.CONNECTION device show "$LNMS_IFACE" 2>/dev/null || true)
      [[ -n $con ]] || { warn "Koneksi NetworkManager untuk $LNMS_IFACE tidak ditemukan, IP statis dilewati."; return 0; }
      run nmcli connection modify "$con" ipv4.method manual ipv4.addresses "$LNMS_IP_CIDR" \
        ipv4.gateway "$LNMS_GATEWAY" ipv4.dns "$dns_csv" ipv4.ignore-auto-dns yes connection.autoconnect yes
      NET_APPLY="live"; NET_LIVE_CMD=(nmcli connection up "$con")
      ;;
    networkd)
      local f=/etc/systemd/network/05-librenms-${LNMS_IFACE}.network
      {
        echo "[Match]"; echo "Name=${LNMS_IFACE}"; echo
        echo "[Network]"; echo "Address=${LNMS_IP_CIDR}"; echo "Gateway=${LNMS_GATEWAY}"
        for d in $LNMS_DNS; do echo "DNS=${d}"; done
      } >"$f"
      NET_APPLY="live"; NET_LIVE_CMD=(bash -c "networkctl reload && networkctl reconfigure '${LNMS_IFACE}'")
      ;;
    ifupdown)
      cp /etc/network/interfaces "/etc/network/interfaces.bak.$(date +%Y%m%d%H%M%S)"
      # Hapus stanza IPv4 lama untuk interface ini, pertahankan yang lain
      awk -v ifc="$LNMS_IFACE" '
        /^[[:space:]]*(auto|allow-hotplug)[[:space:]]/ {
          n = split($0, a, /[[:space:]]+/); out = a[1]; keep = 0
          for (i = 2; i <= n; i++) if (a[i] != "" && a[i] != ifc) { out = out " " a[i]; keep = 1 }
          if (keep) print out
          skip = 0; next
        }
        /^[[:space:]]*iface[[:space:]]/ { if ($2 == ifc && $3 == "inet") { skip = 1; next } else skip = 0 }
        skip && /^[[:space:]]+[^[:space:]]/ { next }
        { skip = 0; print }
      ' /etc/network/interfaces >/etc/network/interfaces.new
      {
        echo
        echo "# IP statis — dibuat oleh install-librenms.sh"
        echo "auto ${LNMS_IFACE}"
        echo "iface ${LNMS_IFACE} inet static"
        echo "    address ${LNMS_IP_CIDR}"
        echo "    gateway ${LNMS_GATEWAY}"
        echo "    dns-nameservers ${LNMS_DNS}"
      } >>/etc/network/interfaces.new
      mv /etc/network/interfaces.new /etc/network/interfaces
      if [[ ! -L /etc/resolv.conf ]]; then
        cp /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null || true
        { for d in $LNMS_DNS; do echo "nameserver $d"; done; } >/etc/resolv.conf
      fi
      NET_APPLY="reboot"
      ;;
    *)
      warn "Stack jaringan tidak dikenali, IP statis tidak diterapkan. Atur manual."
      return 0
      ;;
  esac
  ok "Konfigurasi IP statis disimpan"
}

finish_network() {
  [[ ${NET_APPLY:-none} == none ]] && return 0
  if [[ $NET_APPLY == live ]]; then
    log "Menerapkan IP baru dalam 5 detik (sesi SSH bisa terputus bila IP berubah)..."
    nohup bash -c "sleep 5; $(printf '%q ' "${NET_LIVE_CMD[@]}")" >>"$LOG_FILE" 2>&1 &
    return 0
  fi
  # reboot dibutuhkan (ifupdown)
  if is_unattended; then
    if is_yes "$LNMS_AUTO_REBOOT"; then log "Reboot dalam 10 detik untuk menerapkan IP statis..."; sleep 10; reboot; fi
    warn "Reboot diperlukan untuk menerapkan IP statis: jalankan 'reboot'."
    return 0
  fi
  if whiptail --backtitle "$BACKTITLE" --title "Reboot" --yesno \
     "IP statis $LNMS_IP_CIDR sudah disimpan dan akan aktif setelah reboot.\nContainer LibreNMS akan otomatis jalan lagi.\n\nReboot sekarang?" 11 "$WT_W"; then
    log "Reboot..."; sleep 2; reboot
  else
    warn "Jangan lupa reboot agar IP statis aktif."
  fi
}

# ---------------------------------------------------------------------------
# Ringkasan akhir
# ---------------------------------------------------------------------------
show_summary() {
  local pass_line
  if [[ $ADMIN_PASS_GENERATED == yes ]]; then pass_line="$LNMS_ADMIN_PASS  ${C_YLW}(di-generate, catat & ganti setelah login)${C_RST}"
  else pass_line="(sesuai yang Anda input)"; fi
  printf '\n%s%s============================================================%s\n' "$C_GRN" "$C_BLD" "$C_RST"
  printf '%s%s  LibreNMS berhasil diinstall!%s\n' "$C_GRN" "$C_BLD" "$C_RST"
  printf '%s%s============================================================%s\n' "$C_GRN" "$C_BLD" "$C_RST"
  printf '  URL Web UI     : %s%s%s\n' "$C_BLD" "$WEB_URL" "$C_RST"
  [[ -n $LNMS_PUBLIC_URL ]] && printf '  URL publik     : %s%s%s\n' "$C_BLD" "$LNMS_PUBLIC_URL" "$C_RST"
  printf '  Username       : %s\n' "$LNMS_ADMIN_USER"
  printf '  Password       : %s\n' "$pass_line"
  [[ ${ADMIN_FAILED:-no} == yes ]] && printf '  %sUser admin GAGAL dibuat otomatis — lihat peringatan di atas.%s\n' "$C_RED" "$C_RST"
  [[ ${WIZARD_PENDING:-no} == yes ]] && printf '  %sWizard /install masih aktif — lihat peringatan di atas.%s\n' "$C_YLW" "$C_RST"
  printf '  SNMP community : %s\n' "$LNMS_SNMP_COMMUNITY"
  printf '  Info lengkap   : %s/INSTALL-INFO.txt\n' "$LNMS_INSTALL_DIR"
  printf '  Log instalasi  : %s\n' "$LOG_FILE"
  if [[ $IP_CHANGES == yes ]]; then
    printf '  %sIP akan berubah ke %s — akses lewat IP baru.%s\n' "$C_YLW" "$FINAL_IP" "$C_RST"
  fi
  printf '\n'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  set_defaults
  preflight
  attach_tty
  is_unattended || clear 2>/dev/null || true
  show_banner
  is_unattended || sleep 1
  check_internet
  install_prereqs
  check_os
  detect_system

  if is_unattended; then collect_unattended; else collect_interactive; fi
  finalize_config
  confirm_config
  is_unattended || { clear 2>/dev/null || true; show_banner; }

  log "Memulai instalasi — log detail: $LOG_FILE"
  set_hostname_tz
  install_docker
  write_compose_files
  start_stack
  wait_ready
  create_admin
  finalize_install
  start_workers
  configure_librenms
  setup_self_monitoring
  open_firewall
  write_info_file
  apply_static_network
  show_summary
  _logfile "===== Instalasi selesai ====="
  finish_network
}

# Semua logika ada di dalam fungsi & main dipanggil di baris terakhir,
# supaya aman dijalankan via "curl ... | bash".
main "$@"; exit $?
