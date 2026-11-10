#!/usr/bin/env bash
#
# ============================================================================
#  install-librenms.sh — Installer LibreNMS (Docker) untuk Debian 13 "trixie"
# ============================================================================
#  Versi  : 1.1.0
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

readonly SCRIPT_VERSION="1.1.0"
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
    echo
    echo "Menu pengelolaan (ganti password/username, URL publik, port, SMTP, backup, dll):"
    echo "  gnclibre                 # menu interaktif"
    echo "  gnclibre passwd $LNMS_ADMIN_USER     # ganti password admin"
    echo "  gnclibre status | backup | restart | update"
  } >"$f"
  chmod 600 "$f"
}

# ---------------------------------------------------------------------------
# gnclibre — menu pengelolaan setelah instalasi (/usr/local/bin/gnclibre)
# ---------------------------------------------------------------------------
install_manager() {
  log "Memasang menu pengelolaan 'gnclibre'..."
  cat >/etc/gnclibre.conf <<EOF
# Dibuat oleh install-librenms.sh v${SCRIPT_VERSION}
LNMS_INSTALL_DIR=${LNMS_INSTALL_DIR}
EOF
  chmod 644 /etc/gnclibre.conf
  cat >/usr/local/bin/gnclibre <<'GNCLIBRE_EOF'
#!/usr/bin/env bash
#
# ============================================================================
#  gnclibre — Menu pengelolaan LibreNMS (Docker)
#  Galura Nexa Core — Technology Infrastructure
# ============================================================================
#  Dipasang otomatis oleh install-librenms.sh ke /usr/local/bin/gnclibre.
#
#  Pemakaian (sebagai root):
#    gnclibre                  menu interaktif
#    gnclibre status           ringkasan status
#    gnclibre passwd [user]    ganti password user (default: admin)
#    gnclibre restart          restart semua container
#    gnclibre update           backup DB lalu update image LibreNMS
#    gnclibre backup           backup database
#    gnclibre logs [service]   ikuti log container (default: librenms)
#    gnclibre validate         jalankan validate.php
# ============================================================================

set -uo pipefail

readonly GNCLIBRE_VERSION="1.0.0"
readonly CONF_FILE=${GNCLIBRE_CONF:-/etc/gnclibre.conf}
readonly LOG=${GNCLIBRE_LOG:-/var/log/gnclibre.log}
readonly BT="GNC LibreNMS Manager v${GNCLIBRE_VERSION}  |  Galura Nexa Core"
readonly W=78
readonly DEFAULT_PROXIES="127.0.0.1,172.16.0.0/12,10.0.0.0/8,192.168.0.0/16"
TUI=0

# Logo teks GNC (sama dengan installer)
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

C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YLW=$'\e[33m'; C_CYN=$'\e[36m'; C_RST=$'\e[0m'
say()   { printf '%s==>%s %s\n' "$C_CYN" "$C_RST" "$*"; }
okp()   { printf '%s[ OK ]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warnp() { printf '%s[WARN]%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; }
die()   { printf '%s[GAGAL]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }
logf()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG" 2>/dev/null || true; }

show_banner() {
  local l
  printf '\n'
  for l in "${GNC_TEXT[@]}"; do printf '  %b\n' "$l"; done
  printf '\n  %sGNC LibreNMS Manager v%s%s\n\n' "$C_CYN" "$GNCLIBRE_VERSION" "$C_RST"
}

usage() {
  cat <<'EOF'
Pemakaian (sebagai root):
  gnclibre                  menu interaktif
  gnclibre status           ringkasan status
  gnclibre passwd [user]    ganti password user (default: admin)
  gnclibre restart          restart semua container
  gnclibre update           backup DB lalu update image LibreNMS
  gnclibre backup           backup database
  gnclibre logs [service]   ikuti log container (default: librenms)
  gnclibre validate         jalankan validate.php
  gnclibre version          versi gnclibre
EOF
}

trim() {
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# Validator
# ---------------------------------------------------------------------------
valid_ipv4() {
  local o
  [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do ((10#$o <= 255)) || return 1; done
}
valid_port()      { [[ $1 =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
valid_username()  { [[ $1 =~ ^[A-Za-z0-9._-]{3,32}$ ]]; }
valid_email()     { [[ $1 =~ ^[^[:space:]@\']+@[^[:space:]@\']+$ ]]; }
valid_community() { [[ $1 =~ ^[A-Za-z0-9._@#%+=:-]{1,64}$ ]]; }
valid_tz()        { [[ -n $1 && $1 != *..* && -f /usr/share/zoneinfo/$1 ]]; }
valid_safe_pass() { [[ -n $1 && $1 != *"'"* && $1 != *$'\n'* ]]; }
valid_nonempty()  { [[ -n $1 ]]; }
valid_host()      { valid_ipv4 "$1" || [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]]; }
valid_public_url() { [[ -z $1 || $1 =~ ^https?://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?/?$ ]]; }
valid_proxy_list() {
  local p pf
  [[ $1 == "*" || $1 == "**" ]] && return 0
  [[ -n $1 ]] || return 1
  for p in ${1//,/ }; do
    valid_ipv4 "${p%/*}" || return 1
    if [[ $p == */* ]]; then pf=${p#*/}; [[ $pf =~ ^[0-9]{1,2}$ ]] && ((pf <= 32)) || return 1; fi
  done
}

sql_esc() { local s=${1//\\/\\\\}; printf '%s' "${s//\'/\'\'}"; }

# ---------------------------------------------------------------------------
# Lingkungan & akses Docker
# ---------------------------------------------------------------------------
need_root() {
  [[ $EUID -eq 0 ]] && return 0
  command -v sudo >/dev/null 2>&1 && exec sudo -- "$0" "$@"
  die "Jalankan sebagai root (su - lalu gnclibre)."
}

ensure_whiptail() {
  command -v whiptail >/dev/null 2>&1 && return 0
  say "Memasang whiptail..."
  apt-get install -y whiptail >>"$LOG" 2>&1 || die "whiptail tidak tersedia. Jalankan: apt-get install -y whiptail"
}

load_env() {
  local f
  # shellcheck disable=SC1090
  [[ -r $CONF_FILE ]] && . "$CONF_FILE"
  DIR=${LNMS_INSTALL_DIR:-}
  if [[ -z $DIR || ! -d $DIR ]]; then
    DIR=$(docker ps -a --filter label=com.docker.compose.service=librenms \
      --format '{{.Label "com.docker.compose.project.working_dir"}}' 2>/dev/null | head -n1)
  fi
  [[ -n $DIR && -d $DIR ]] || die "Instalasi LibreNMS tidak ditemukan. Isi LNMS_INSTALL_DIR=/path di $CONF_FILE"
  CF=""
  for f in compose.yml compose.yaml docker-compose.yml docker-compose.yaml; do
    [[ -f $DIR/$f ]] && { CF=$DIR/$f; break; }
  done
  [[ -n $CF ]] || die "File compose tidak ditemukan di $DIR"
  ENVF=$DIR/.env; LENV=$DIR/librenms.env; DENV=$DIR/librenms/.env; MENV=$DIR/msmtpd.env
  INFO=$DIR/INSTALL-INFO.txt; BK=$DIR/backups
  if docker compose version >/dev/null 2>&1; then DC=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then DC=(docker-compose)
  else die "Docker Compose tidak ditemukan."; fi
}

dc()     { "${DC[@]}" -f "$CF" --project-directory "$DIR" "$@"; }
lnms_c() { dc exec -T --user librenms librenms lnms "$@"; }
# SQL dibaca dari stdin; kredensial diambil dari env container database
sqlq()   { dc exec -T db sh -c 'exec mariadb -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" -N -B'; }
services() { dc config --services 2>/dev/null; }
has_service() { services | grep -qx "$1"; }

web_port() {
  local p
  p=$(dc port librenms 8000 2>/dev/null | head -n1); p=${p##*:}
  [[ $p =~ ^[0-9]+$ ]] || p=$(envget "$ENVF" HTTP_PORT)
  echo "${p:-80}"
}
local_ip()  { local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}'); echo "${ip:-127.0.0.1}"; }
local_url() { local p; p=$(web_port); if [[ $p == 80 ]]; then echo "http://$(local_ip)"; else echo "http://$(local_ip):$p"; fi; }
web_code()  { curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:$(web_port)/login" 2>/dev/null; }

wait_web() {
  local i c
  for ((i = 1; i <= 60; i++)); do
    c=$(web_code); [[ $c == 200 || $c == 302 ]] && return 0
    sleep 3
  done
  return 1
}

# ---------------------------------------------------------------------------
# File .env & INSTALL-INFO (menjaga owner/permission file asli)
# ---------------------------------------------------------------------------
envget() { [[ -f $1 ]] && K="$2" awk 'index($0, ENVIRON["K"] "=") == 1 { print substr($0, length(ENVIRON["K"]) + 2); exit }' "$1"; return 0; }
envset() {
  local f=$1 tmp; tmp=$(mktemp)
  [[ -f $f ]] || { touch "$f"; chmod 600 "$f"; }
  K="$2" V="$3" awk 'BEGIN { k = ENVIRON["K"]; v = ENVIRON["V"] }
    index($0, k "=") == 1 { if (!d) { print k "=" v; d = 1 }; next } { print }
    END { if (!d) print k "=" v }' "$f" >"$tmp" && cat "$tmp" >"$f"
  rm -f "$tmp"
}
envdel() {
  local f=$1 tmp; [[ -f $f ]] || return 0; tmp=$(mktemp)
  K="$2" awk 'index($0, ENVIRON["K"] "=") != 1' "$f" >"$tmp" && cat "$tmp" >"$f"
  rm -f "$tmp"
}
info_get() { [[ -f $INFO ]] && P="$1" awk 'index($0, ENVIRON["P"]) == 1 { sub(/^[^:]*: */, ""); print; exit }' "$INFO"; return 0; }
info_set() {
  [[ -f $INFO ]] || return 0
  local tmp; tmp=$(mktemp)
  P="$1" V="$2" awk 'index($0, ENVIRON["P"]) == 1 { print ENVIRON["P"] ": " ENVIRON["V"]; f = 1; next } { print }
    END { if (!f) print ENVIRON["P"] ": " ENVIRON["V"] }' "$INFO" >"$tmp" && cat "$tmp" >"$INFO"
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# Helper tampilan (whiptail di mode menu, teks biasa di mode CLI)
# ---------------------------------------------------------------------------
ui_msg()   { if ((TUI)); then whiptail --backtitle "$BT" --title "$1" --msgbox "$2" "${3:-13}" "$W"; else printf '\n%s\n%b\n' "$1" "$2"; fi; return 0; }
ui_info()  { if ((TUI)); then whiptail --backtitle "$BT" --title "Mohon tunggu" --infobox "$1" 8 "$W"; else say "$1"; fi; logf "$1"; }
ui_yesno() { local o=(); [[ ${3:-} == no ]] && o=(--defaultno); whiptail --backtitle "$BT" --title "$1" "${o[@]}" --yesno "$2" 13 "$W"; }
ui_menu()  { local t=$1 x=$2; shift 2; whiptail --backtitle "$BT" --title "$t" --menu "$x" 22 "$W" 12 "$@" 3>&1 1>&2 2>&3; }

# ui_input VAR "Judul" "Teks" "default" [validator] ["pesan error"]   (return 1 = batal)
ui_input() {
  local __v=$1 title=$2 text=$3 def=$4 val=${5:-} err=${6:-"Input tidak valid, silakan ulangi."} out
  while true; do
    out=$(whiptail --backtitle "$BT" --title "$title" --inputbox "$text" 15 "$W" "$def" 3>&1 1>&2 2>&3) || return 1
    out=$(trim "$out")
    if [[ -z $val ]] || "$val" "$out"; then printf -v "$__v" '%s' "$out"; return 0; fi
    ui_msg "Input tidak valid" "$err"; def=$out
  done
}

# ui_pass VAR "Judul" minlen [validator] ["pesan error"]
ui_pass() {
  local __v=$1 title=$2 min=${3:-8} val=${4:-} err=${5:-} p1 p2
  while true; do
    p1=$(whiptail --backtitle "$BT" --title "$title" --passwordbox "Masukkan password (minimal $min karakter):" 10 "$W" 3>&1 1>&2 2>&3) || return 1
    if ((${#p1} < min)); then ui_msg "Password terlalu pendek" "Password minimal $min karakter."; continue; fi
    if [[ -n $val ]] && ! "$val" "$p1"; then ui_msg "Password tidak valid" "$err"; continue; fi
    p2=$(whiptail --backtitle "$BT" --title "$title" --passwordbox "Ulangi password:" 10 "$W" 3>&1 1>&2 2>&3) || return 1
    [[ $p1 == "$p2" ]] || { ui_msg "Password tidak sama" "Kedua password tidak sama, silakan ulangi."; continue; }
    printf -v "$__v" '%s' "$p1"; return 0
  done
}

# ui_run "Judul" perintah...  -> jalankan, tampilkan output di textbox
ui_run() {
  local t=$1 tmp rc; shift; tmp=$(mktemp)
  ((TUI)) && whiptail --backtitle "$BT" --title "Mohon tunggu" --infobox "Menjalankan: $t ..." 8 "$W"
  "$@" >"$tmp" 2>&1; rc=$?
  sed -i 's/\x1b\[[0-9;]*m//g' "$tmp"
  [[ -s $tmp ]] || echo "(tidak ada output)" >"$tmp"
  if ((TUI)); then whiptail --backtitle "$BT" --title "$t" --scrolltext --textbox "$tmp" 24 "$W"; else cat "$tmp"; fi
  rm -f "$tmp"; return $rc
}

apply_stack() {
  ui_info "Menerapkan perubahan (recreate container)..."
  dc up -d >>"$LOG" 2>&1 && wait_web
}

fmt_cols() { awk -F'\t' '{ printf "%-22s %-28s %s\n", $1, $2, $3 }'; }

# ---------------------------------------------------------------------------
# 1. Status
# ---------------------------------------------------------------------------
status_text() {
  local code nu nd nup pub
  code=$(web_code)
  pub=$(envget "$LENV" LIBRENMS_BASE_URL)
  nu=$(echo "SELECT COUNT(*) FROM users;" | sqlq 2>/dev/null)
  nd=$(echo "SELECT COUNT(*) FROM devices;" | sqlq 2>/dev/null)
  nup=$(echo "SELECT COUNT(*) FROM devices WHERE status=1;" | sqlq 2>/dev/null)
  echo "Folder instalasi : $DIR"
  echo "URL lokal        : $(local_url)"
  echo "URL publik       : ${pub:--}"
  echo "Web UI           : $([[ $code == 200 || $code == 302 ]] && echo "OK (HTTP $code)" || echo "TIDAK MERESPONS (${code:-000})")"
  echo "Jumlah user      : ${nu:-?}"
  echo "Device up/total  : ${nup:-?}/${nd:-?}"
  echo "Disk data / DB   : $(du -sh "$DIR/librenms" 2>/dev/null | cut -f1) / $(du -sh "$DIR/db" 2>/dev/null | cut -f1)"
  echo "Zona waktu       : $(envget "$ENVF" TZ)"
  echo
  echo "Container:"
  dc ps --format 'table {{.Service}}\t{{.Status}}' 2>/dev/null || dc ps
  if [[ -f $INFO ]]; then echo; echo "----- INSTALL-INFO.txt -----"; cat "$INFO"; fi
}

# ---------------------------------------------------------------------------
# 2. User
# ---------------------------------------------------------------------------
user_exists() { local n; n=$(printf "SELECT COUNT(*) FROM users WHERE username='%s';\n" "$(sql_esc "$1")" | sqlq 2>>"$LOG"); [[ $n =~ ^[1-9] ]]; }

user_table() {
  { printf 'USERNAME\tEMAIL\tDIBUAT\n'
    echo "SELECT username, IFNULL(NULLIF(email,''),'-'), created_at FROM users ORDER BY user_id;" | sqlq
  } | fmt_cols
}

pick_user() {
  local __v=$1 title=$2 u sel items=() us=()
  mapfile -t us < <(echo "SELECT username FROM users ORDER BY username;" | sqlq 2>>"$LOG")
  ((${#us[@]})) || { ui_msg "User" "Belum ada user / database tidak bisa diakses."; return 1; }
  for u in "${us[@]}"; do items+=("$u" ""); done
  sel=$(ui_menu "$title" "Pilih user:" "${items[@]}") || return 1
  printf -v "$__v" '%s' "$sel"
}

set_password() { # set_password user pass
  local hash n eu; eu=$(sql_esc "$1")
  hash=$(printf '%s' "$2" | dc exec -T librenms php -r 'echo password_hash(stream_get_contents(STDIN), PASSWORD_BCRYPT);' 2>>"$LOG")
  [[ $hash == '$2y$'* ]] || { logf "Gagal membuat hash password"; return 1; }
  n=$(printf "UPDATE users SET password='%s' WHERE username='%s'; SELECT ROW_COUNT();\n" "$hash" "$eu" | sqlq 2>>"$LOG")
  [[ $n == 1 ]] || return 1
  printf "UPDATE users SET remember_token=NULL WHERE username='%s';\n" "$eu" | sqlq >>"$LOG" 2>&1 || true
}

do_passwd() {
  local u=${1:-} p
  if [[ -z $u ]]; then pick_user u "Ganti Password" || return 0; fi
  user_exists "$u" || { ui_msg "User tidak ditemukan" "User '$u' tidak ada.\nLihat daftar user di menu Akun Admin / User."; return 1; }
  ui_pass p "Password baru untuk '$u'" 8 || return 0
  ui_info "Mengganti password '$u'..."
  if set_password "$u" "$p"; then
    [[ $(info_get "Admin username   ") == "$u" ]] && info_set "Admin password   " "(diubah via gnclibre $(date +%F))"
    logf "Password user $u diganti"
    ui_msg "Berhasil" "Password user '$u' berhasil diganti.\nSilakan login ulang di Web UI."
  else
    ui_msg "Gagal" "Password gagal diganti. Detail: $LOG"; return 1
  fi
}

do_rename() {
  local old new n
  pick_user old "Ganti Username" || return 0
  ui_input new "Username baru" "Username baru untuk '$old':\n(3-32 karakter: huruf, angka, titik, '_' atau '-')" "$old" valid_username \
    "Username 3-32 karakter: huruf, angka, titik, '_' atau '-'." || return 0
  [[ $new == "$old" ]] && return 0
  user_exists "$new" && { ui_msg "Sudah dipakai" "Username '$new' sudah ada."; return 1; }
  n=$(printf "UPDATE users SET username='%s' WHERE username='%s'; SELECT ROW_COUNT();\n" "$(sql_esc "$new")" "$(sql_esc "$old")" | sqlq 2>>"$LOG")
  if [[ $n == 1 ]]; then
    [[ $(info_get "Admin username   ") == "$old" ]] && info_set "Admin username   " "$new"
    logf "Username $old diganti menjadi $new"
    ui_msg "Berhasil" "Username '$old' sekarang menjadi '$new'.\nPassword tidak berubah. Silakan login ulang."
  else
    ui_msg "Gagal" "Username gagal diganti. Detail: $LOG"; return 1
  fi
}

do_adduser() {
  local u r e p
  ui_input u "Tambah User" "Username baru:" "" valid_username "Username 3-32 karakter: huruf, angka, titik, '_' atau '-'." || return 0
  user_exists "$u" && { ui_msg "Sudah ada" "Username '$u' sudah ada."; return 1; }
  r=$(ui_menu "Role" "Hak akses user '$u':" \
    "admin"       "Administrator (akses penuh)" \
    "global-read" "Lihat semua device (read-only)" \
    "user"        "User biasa (hanya device yang diberikan)") || return 0
  ui_input e "Tambah User" "Email user:" "$u@localhost" valid_email "Format email tidak valid." || return 0
  ui_pass p "Password untuk '$u'" 8 || return 0
  ui_run "Tambah user $u" lnms_c user:add --role="$r" --email="$e" --password="$p" "$u"
  logf "Tambah user $u (role $r)"
}

m_users() {
  local c
  while true; do
    c=$(ui_menu "Akun Admin / User" "Kelola akun login Web UI LibreNMS:" \
      1 "Daftar user" 2 "Ganti password user" 3 "Ganti username" 4 "Tambah user baru" 0 "Kembali") || return 0
    case $c in
      1) ui_run "Daftar User" user_table ;;
      2) do_passwd "" ;;
      3) do_rename ;;
      4) do_adduser ;;
      0) return 0 ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# 3. Akses Web
# ---------------------------------------------------------------------------
set_proxies() { envset "$LENV" APP_TRUSTED_PROXIES "$1"; [[ -f $DENV ]] && envset "$DENV" APP_TRUSTED_PROXIES "$1"; return 0; }

proxy_https_ok() { # 0 = halaman tidak memuat http://host (tidak ada Mixed Content)
  local host=${1#*://}; host=${host%%/*}
  ! curl -s -m 10 -H "Host: $host" -H "X-Forwarded-Proto: https" -H "X-Forwarded-Host: $host" \
      "http://127.0.0.1:$(web_port)/login" 2>/dev/null | grep -q "http://${host}"
}

do_public_url() {
  local cur u res
  cur=$(envget "$LENV" LIBRENMS_BASE_URL); cur=${cur%/}
  ui_input u "URL Publik" "URL publik bila diakses lewat Cloudflare Tunnel / reverse proxy.\nContoh: https://nms.klien.com\n\nKosongkan untuk akses lokal saja: $(local_url)" \
    "$cur" valid_public_url "Format salah. Contoh: https://nms.klien.com (tanpa path)" || return 0
  u=${u%/}
  if [[ -n $u ]]; then
    envset "$LENV" LIBRENMS_BASE_URL "$u/"
    [[ -n $(envget "$LENV" APP_TRUSTED_PROXIES) ]] || set_proxies "$DEFAULT_PROXIES"
  else
    envdel "$LENV" LIBRENMS_BASE_URL
  fi
  apply_stack || { ui_msg "Gagal" "Web UI tidak kembali normal. Cek: gnclibre logs"; return 1; }
  lnms_c config:set base_url "${u:-$(local_url)}/" >>"$LOG" 2>&1
  info_set "URL publik       " "${u:--}"
  logf "URL publik diset ke ${u:-(kosong)}"
  if [[ -z $u ]]; then
    ui_msg "Berhasil" "URL publik dihapus. LibreNMS diakses lewat $(local_url)"
    return 0
  fi
  if proxy_https_ok "$u"; then res="Cek HTTPS via proxy: OK (tanpa Mixed Content)"
  else res="PERINGATAN: halaman masih memuat http://. Cek menu Trusted Proxy."; fi
  ui_msg "Berhasil" "URL publik: $u\n$res\n\nDi Cloudflare Tunnel arahkan service hostname ini ke:\n  http://$(local_ip):$(web_port)" 15
}

do_proxies() {
  local cur p
  cur=$(envget "$LENV" APP_TRUSTED_PROXIES)
  ui_input p "Trusted Proxy" "IP/CIDR reverse proxy (cloudflared) yang dipercaya, pisahkan koma.\nDefault: $DEFAULT_PROXIES" \
    "${cur:-$DEFAULT_PROXIES}" valid_proxy_list "Isi IPv4/CIDR dipisah koma, contoh: 127.0.0.1,172.16.0.0/12" || return 0
  set_proxies "$p"
  apply_stack || { ui_msg "Gagal" "Web UI tidak kembali normal. Cek: gnclibre logs"; return 1; }
  info_set "Trusted proxies  " "$p"
  logf "Trusted proxies diset ke $p"
  ui_msg "Berhasil" "Trusted proxy sekarang:\n$p"
}

do_port() {
  local cur p
  if ! grep -q '\${HTTP_PORT}' "$CF"; then
    ui_msg "Tidak didukung" "File compose ini memakai port tetap (bukan buatan installer GNC).\nUbah port secara manual di:\n$CF" 12
    return 1
  fi
  cur=$(web_port)
  while true; do
    ui_input p "Port Web" "Port HTTP Web UI LibreNMS (sekarang: $cur).\n80 = akses langsung http://IP tanpa menulis port." "$cur" valid_port "Port harus angka 1-65535." || return 0
    [[ $p == "$cur" ]] && return 0
    if [[ -n $(ss -Hltn "sport = :$p" 2>/dev/null) ]]; then ui_msg "Port dipakai" "Port $p sudah dipakai aplikasi lain."; continue; fi
    break
  done
  envset "$ENVF" HTTP_PORT "$p"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then ufw allow "$p/tcp" >>"$LOG" 2>&1; fi
  apply_stack || { ui_msg "Gagal" "Web UI tidak merespons di port $p. Cek: gnclibre logs"; return 1; }
  info_set "URL Web UI       " "$(local_url)"
  logf "Port web diubah $cur -> $p"
  ui_msg "Berhasil" "Web UI sekarang di: $(local_url)\n\nBila memakai Cloudflare Tunnel, ubah juga service-nya ke port $p."
}

web_settings() {
  echo "URL lokal        : $(local_url)"
  echo "URL publik       : $(envget "$LENV" LIBRENMS_BASE_URL)"
  echo "base_url (DB)    : $(lnms_c config:get base_url 2>/dev/null)"
  echo "Trusted proxies  : $(envget "$LENV" APP_TRUSTED_PROXIES)"
  echo "Port web         : $(web_port)"
}

m_web() {
  local c
  while true; do
    c=$(ui_menu "Akses Web" "Pengaturan akses Web UI:" \
      1 "Ubah URL publik (Cloudflare / domain)" 2 "Ubah trusted proxy" 3 "Ubah port web" 4 "Lihat setting saat ini" 0 "Kembali") || return 0
    case $c in
      1) do_public_url ;;
      2) do_proxies ;;
      3) do_port ;;
      4) ui_run "Setting Akses Web" web_settings ;;
      0) return 0 ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# 4. SNMP & Device
# ---------------------------------------------------------------------------
default_community() { lnms_c config:get snmp.community 2>/dev/null | tr -d '[]" \r\n' | cut -d, -f1; }

device_table() {
  { printf 'HOSTNAME\tSYSNAME\tOS / STATUS\n'
    echo "SELECT hostname, IFNULL(sysName,'-'), CONCAT(IFNULL(os,'-'), ' / ', IF(status=1,'up','DOWN')) FROM devices ORDER BY hostname;" | sqlq
  } | fmt_cols
}

do_add_device() {
  local h c f=()
  ui_input h "Tambah Device" "IP address atau hostname device:" "" valid_host "IP/hostname tidak valid." || return 0
  ui_input c "Tambah Device" "SNMP v2c community untuk $h:" "$(default_community)" valid_community \
    "Community hanya huruf, angka, dan simbol ._@#%+=:- (tanpa spasi)." || return 0
  ui_yesno "Force Add" "Tambahkan tanpa cek ping/SNMP (force add)?\n\nPilih 'No' (disarankan) agar LibreNMS memeriksa koneksi dulu." no && f=(--force)
  ui_run "Tambah device $h" lnms_c device:add --v2c -c "$c" "${f[@]}" "$h"
  logf "Tambah device $h"
}

do_community() {
  local cur c ip
  cur=$(default_community)
  ui_input c "SNMP Community" "Community default untuk device baru & auto-discovery (sekarang: ${cur:-?}):" "$cur" valid_community \
    "Community hanya huruf, angka, dan simbol ._@#%+=:- (tanpa spasi)." || return 0
  [[ $c == "$cur" ]] && return 0
  if ! lnms_c config:set snmp.community "[\"$c\"]" >>"$LOG" 2>&1; then ui_msg "Gagal" "Gagal menyimpan community. Detail: $LOG"; return 1; fi
  info_set "SNMP community   " "$c"
  if grep -q 'install-librenms.sh' /etc/snmp/snmpd.conf 2>/dev/null &&
     ui_yesno "snmpd PC ini" "Ubah juga community snmpd di PC LibreNMS ini (monitoring diri sendiri)?"; then
    sed -i "s/^\(rocommunity[[:space:]]\+\)[^[:space:]]\+/\1$c/" /etc/snmp/snmpd.conf
    systemctl restart snmpd >>"$LOG" 2>&1
    ip=$(local_ip)
    printf "UPDATE devices SET community='%s' WHERE hostname IN ('%s','127.0.0.1','localhost');\n" "$c" "$ip" | sqlq >>"$LOG" 2>&1
  fi
  logf "Community default diubah"
  ui_msg "Berhasil" "Community default sekarang: $c\n\nDevice yang sudah terdaftar tetap memakai community lamanya.\nUbah per device di Web UI: Device > Settings (gear) > SNMP." 13
}

do_dup_sysname() {
  local cur
  cur=$(lnms_c config:get allow_duplicate_sysName 2>/dev/null | tr -d '[:space:]')
  if ui_yesno "sysName Duplikat" "Status sekarang: ${cur:-false}\n\nIzinkan beberapa device dengan sysName yang sama?\n(Perlu bila banyak switch masih memakai hostname default, mis. 'ruijie')"; then
    lnms_c config:set allow_duplicate_sysName true >>"$LOG" 2>&1 && ui_msg "Berhasil" "sysName duplikat: DIIZINKAN"
  else
    lnms_c config:set allow_duplicate_sysName false >>"$LOG" 2>&1 && ui_msg "Berhasil" "sysName duplikat: TIDAK diizinkan"
  fi
}

m_snmp() {
  local c
  while true; do
    c=$(ui_menu "SNMP & Device" "Kelola device yang dimonitor:" \
      1 "Daftar device" 2 "Tambah device (SNMP v2c)" 3 "Ubah community default" 4 "Izinkan sysName duplikat (on/off)" 0 "Kembali") || return 0
    case $c in
      1) ui_run "Daftar Device" device_table ;;
      2) do_add_device ;;
      3) do_community ;;
      4) do_dup_sysname ;;
      0) return 0 ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# 5. Email (SMTP relay via msmtpd)
# ---------------------------------------------------------------------------
ensure_msmtpd() {
  has_service msmtpd && return 0
  if ! grep -q 'install-librenms.sh' "$CF"; then
    ui_msg "Tidak didukung" "Service msmtpd tidak ada di $CF.\nTambahkan service msmtpd secara manual." 11; return 1
  fi
  cp -p "$CF" "$CF.bak"
  cat >>"$CF" <<'EOF'

  msmtpd:
    image: crazymax/msmtpd:latest
    container_name: librenms_msmtpd
    env_file:
      - "./msmtpd.env"
    restart: always
EOF
  dc config -q >>"$LOG" 2>&1 && return 0
  cp -p "$CF.bak" "$CF"
  ui_msg "Gagal" "Gagal menambahkan service msmtpd ke compose. Detail: $LOG"; return 1
}

do_smtp() {
  local h p u pw f tls=on
  h=$(envget "$MENV" SMTP_HOST); p=$(envget "$MENV" SMTP_PORT); u=$(envget "$MENV" SMTP_USER); f=$(envget "$MENV" SMTP_FROM)
  ui_input h "Email Alert" "SMTP server:" "${h:-smtp.gmail.com}" valid_host "Host SMTP tidak valid." || return 0
  ui_input p "Email Alert" "Port SMTP (587 = STARTTLS, 465 = SSL/TLS):" "${p:-587}" valid_port "Port harus angka 1-65535." || return 0
  ui_input u "Email Alert" "Username SMTP (biasanya alamat email):" "$u" valid_nonempty "Username tidak boleh kosong." || return 0
  ui_pass pw "Password SMTP (Gmail: App Password)" 1 valid_safe_pass "Password tidak boleh mengandung tanda kutip tunggal (')." || return 0
  ui_input f "Email Alert" "Alamat pengirim (From):" "${f:-$u}" valid_email "Format email tidak valid." || return 0
  [[ $p == 465 ]] && tls=off
  [[ -f $MENV ]] || { touch "$MENV"; chmod 600 "$MENV"; }
  cat >"$MENV" <<EOF
SMTP_HOST=${h}
SMTP_PORT=${p}
SMTP_TLS=on
SMTP_STARTTLS=${tls}
SMTP_TLS_CHECKCERT=on
SMTP_AUTH=on
SMTP_USER=${u}
SMTP_PASSWORD='${pw}'
SMTP_FROM=${f}
EOF
  chmod 600 "$MENV"
  ensure_msmtpd || return 1
  apply_stack || { ui_msg "Gagal" "Container tidak kembali normal. Cek: gnclibre logs"; return 1; }
  if lnms_c config:set email_backend smtp >>"$LOG" 2>&1 &&
     lnms_c config:set email_smtp_host msmtpd >>"$LOG" 2>&1 &&
     lnms_c config:set email_smtp_port 2500 >>"$LOG" 2>&1 &&
     lnms_c config:set email_smtp_auth false >>"$LOG" 2>&1 &&
     lnms_c config:set email_from "$f" >>"$LOG" 2>&1; then
    logf "SMTP diatur ke $h:$p"
    ui_msg "Berhasil" "Email alert dikirim lewat $h:$p sebagai $f.\n\nUji kirim: Web UI > Alerts > Alert Transports > buat transport Mail > Test." 12
  else
    ui_msg "Gagal" "Sebagian setting email gagal disimpan. Detail: $LOG"; return 1
  fi
}

mail_settings() {
  if [[ -f $MENV ]]; then grep -v '^SMTP_PASSWORD' "$MENV"; echo "SMTP_PASSWORD=********"; else echo "msmtpd.env belum ada (SMTP belum diatur)."; fi
  echo; echo "email_backend : $(lnms_c config:get email_backend 2>/dev/null)"
  echo "email_from    : $(lnms_c config:get email_from 2>/dev/null)"
}

m_mail() {
  local c
  while true; do
    c=$(ui_menu "Email Alert" "Pengiriman email notifikasi alert:" 1 "Atur / ubah SMTP" 2 "Lihat setting email" 0 "Kembali") || return 0
    case $c in 1) do_smtp ;; 2) ui_run "Setting Email" mail_settings ;; 0) return 0 ;; esac
  done
}

# ---------------------------------------------------------------------------
# 6. Zona waktu
# ---------------------------------------------------------------------------
m_tz() {
  local cur tz
  cur=$(envget "$ENVF" TZ)
  tz=$(ui_menu "Zona Waktu" "Zona waktu sekarang: ${cur:-?}" \
    "Asia/Jakarta" "WIB  (UTC+7)" "Asia/Makassar" "WITA (UTC+8)" "Asia/Jayapura" "WIT  (UTC+9)" \
    "UTC" "UTC" "lainnya" "Ketik manual (mis. Asia/Singapore)") || return 0
  if [[ $tz == lainnya ]]; then
    ui_input tz "Zona Waktu" "Nama zona waktu (Region/Kota):" "$cur" valid_tz "Zona waktu tidak ditemukan. Contoh: Asia/Singapore" || return 0
  fi
  [[ $tz == "$cur" ]] && return 0
  envset "$ENVF" TZ "$tz"
  timedatectl set-timezone "$tz" >>"$LOG" 2>&1 || ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime
  apply_stack || { ui_msg "Gagal" "Container tidak kembali normal. Cek: gnclibre logs"; return 1; }
  info_set "Zona waktu       " "$tz"
  logf "Zona waktu diubah ke $tz"
  ui_msg "Berhasil" "Zona waktu sekarang: $tz"
}

# ---------------------------------------------------------------------------
# 7. Layanan
# ---------------------------------------------------------------------------
do_update() {
  local f
  ui_info "Backup database sebelum update..."
  f=$(backup_db) || { ui_msg "Gagal" "Backup database gagal, update dibatalkan. Detail: $LOG"; return 1; }
  ui_info "Download image terbaru (bisa beberapa menit)..."
  dc pull >>"$LOG" 2>&1 || { ui_msg "Gagal" "Download image gagal. Cek koneksi internet. Detail: $LOG"; return 1; }
  ui_info "Menjalankan versi baru & migrasi database..."
  dc up -d >>"$LOG" 2>&1 && wait_web || { ui_msg "Gagal" "LibreNMS belum merespons setelah update. Cek: gnclibre logs\nBackup DB: $f"; return 1; }
  docker image prune -f >>"$LOG" 2>&1
  logf "Update selesai (backup $f)"
  ui_msg "Berhasil" "LibreNMS sudah diupdate.\nBackup database sebelum update:\n$f"
}

m_service() {
  local c s items=()
  while true; do
    c=$(ui_menu "Layanan" "Kontrol container LibreNMS:" \
      1 "Restart semua" 2 "Restart Web UI saja" 3 "Stop semua" 4 "Start semua" \
      5 "Lihat log" 6 "Validasi LibreNMS (validate.php)" 7 "Update LibreNMS ke image terbaru" 0 "Kembali") || return 0
    case $c in
      1) ui_info "Restart semua container..."; dc restart >>"$LOG" 2>&1 && wait_web && ui_msg "Berhasil" "Semua container sudah di-restart." || ui_msg "Gagal" "Cek: gnclibre logs" ;;
      2) ui_info "Restart Web UI..."; dc restart librenms >>"$LOG" 2>&1 && wait_web && ui_msg "Berhasil" "Web UI sudah di-restart." || ui_msg "Gagal" "Cek: gnclibre logs" ;;
      3) ui_yesno "Stop" "Hentikan semua container? Monitoring akan berhenti." no && { ui_info "Menghentikan container..."; dc stop >>"$LOG" 2>&1; ui_msg "Selesai" "Semua container dihentikan. Jalankan lagi lewat menu Start semua."; } ;;
      4) ui_info "Menjalankan container..."; dc up -d >>"$LOG" 2>&1 && wait_web && ui_msg "Berhasil" "Semua container berjalan." || ui_msg "Gagal" "Cek: gnclibre logs" ;;
      5) items=(); while read -r s; do [[ -n $s ]] && items+=("$s" ""); done < <(services)
         s=$(ui_menu "Lihat Log" "Pilih container:" "${items[@]}") && ui_run "Log $s (200 baris terakhir)" dc logs --no-color --tail 200 "$s" ;;
      6) ui_run "Validasi LibreNMS" dc exec -T --user librenms librenms php validate.php ;;
      7) ui_yesno "Update" "Update LibreNMS ke image terbaru?\n\nDatabase akan dibackup otomatis dulu. Web UI tidak bisa diakses 1-3 menit." no && do_update ;;
      0) return 0 ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# 8. Backup & Restore
# ---------------------------------------------------------------------------
backup_db() { # tulis path file ke stdout
  local f
  mkdir -p "$BK"; chmod 700 "$BK"
  f=$BK/librenms-db-$(date +%Y%m%d-%H%M%S).sql.gz
  if dc exec -T db sh -c 'exec mariadb-dump --single-transaction --quick -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE"' 2>>"$LOG" | gzip >"$f" &&
     zcat "$f" | grep -q 'CREATE TABLE'; then
    chmod 600 "$f"; logf "Backup DB: $f"; echo "$f"; return 0
  fi
  rm -f "$f"; logf "Backup DB gagal"; return 1
}

backup_full() {
  local db t items=() i
  db=$(backup_db) || return 1
  t=$BK/librenms-files-$(date +%Y%m%d-%H%M%S).tar.gz
  for i in librenms .env librenms.env msmtpd.env "$(basename "$CF")" INSTALL-INFO.txt; do [[ -e $DIR/$i ]] && items+=("$i"); done
  tar -czf "$t" -C "$DIR" --exclude='librenms/logs' "${items[@]}" 2>>"$LOG" || { rm -f "$t"; return 1; }
  chmod 600 "$t"; logf "Backup file: $t"
  printf '%s\n%s\n' "$db" "$t"
}

backup_list() {
  if compgen -G "$BK/*" >/dev/null; then ls -lh --time-style='+%Y-%m-%d %H:%M' "$BK" | awk 'NR>1 {print $6" "$7"  "$5"  "$8}'
  else echo "Belum ada backup di $BK"; fi
  echo; echo "Folder: $BK"
}

do_restore() {
  local files=() items=() f sel conf pre svc stop=()
  mapfile -t files < <(ls -1t "$BK"/librenms-db-*.sql.gz 2>/dev/null)
  ((${#files[@]})) || { ui_msg "Restore" "Belum ada file backup database di $BK"; return 1; }
  for f in "${files[@]}"; do items+=("$(basename "$f")" "$(du -h "$f" | cut -f1)"); done
  sel=$(ui_menu "Restore Database" "Pilih backup (terbaru di atas):" "${items[@]}") || return 0
  ui_input conf "Konfirmasi Restore" "Database LibreNMS sekarang akan DIGANTI dengan:\n$sel\n\nDatabase saat ini dibackup otomatis dulu.\nKetik RESTORE untuk melanjutkan:" "" || return 0
  [[ $conf == RESTORE ]] || { ui_msg "Dibatalkan" "Restore dibatalkan."; return 0; }
  ui_info "Backup database saat ini..."
  pre=$(backup_db) || { ui_msg "Gagal" "Backup database saat ini gagal, restore dibatalkan."; return 1; }
  while read -r svc; do [[ $svc =~ ^(db|redis|librenms|msmtpd)$ || -z $svc ]] || stop+=("$svc"); done < <(services)
  ui_info "Menghentikan poller & restore database..."
  ((${#stop[@]})) && dc stop "${stop[@]}" >>"$LOG" 2>&1
  if zcat "$BK/$sel" | sqlq >>"$LOG" 2>&1; then
    dc restart librenms >>"$LOG" 2>&1; dc up -d >>"$LOG" 2>&1; wait_web
    logf "Restore DB dari $sel (backup sebelum restore: $pre)"
    ui_msg "Berhasil" "Database dipulihkan dari $sel.\n\nBackup sebelum restore:\n$pre"
  else
    dc up -d >>"$LOG" 2>&1
    ui_msg "Gagal" "Restore gagal. Database sebelumnya ada di:\n$pre\nDetail: $LOG"; return 1
  fi
}

m_backup() {
  local c out
  while true; do
    c=$(ui_menu "Backup & Restore" "Backup disimpan di $BK" \
      1 "Backup database (cepat)" 2 "Backup lengkap (database + grafik RRD + config)" 3 "Restore database" 4 "Daftar backup" 0 "Kembali") || return 0
    case $c in
      1) ui_info "Backup database..."; if out=$(backup_db); then ui_msg "Berhasil" "Backup database:\n$out"; else ui_msg "Gagal" "Backup gagal. Detail: $LOG"; fi ;;
      2) ui_info "Backup lengkap (bisa beberapa menit)..."; if out=$(backup_full); then ui_msg "Berhasil" "Backup tersimpan:\n$out" 12; else ui_msg "Gagal" "Backup gagal. Detail: $LOG"; fi ;;
      3) do_restore ;;
      4) ui_run "Daftar Backup" backup_list ;;
      0) return 0 ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Menu utama
# ---------------------------------------------------------------------------
main_menu() {
  local c code st
  while true; do
    code=$(web_code)
    if [[ $code == 200 || $code == 302 ]]; then st="Web UI: OK"; else st="Web UI: TIDAK MERESPONS"; fi
    c=$(ui_menu "Menu Utama" "LibreNMS di $(local_url)   |   $st\n\nPilih menu:" \
      1 "Status & informasi" \
      2 "Akun admin / user (password, username)" \
      3 "Akses web (URL publik, proxy, port)" \
      4 "SNMP & device" \
      5 "Email alert (SMTP)" \
      6 "Zona waktu" \
      7 "Layanan (restart, log, update)" \
      8 "Backup & restore" \
      0 "Keluar") || return 0
    case $c in
      1) ui_run "Status LibreNMS" status_text ;;
      2) m_users ;;
      3) m_web ;;
      4) m_snmp ;;
      5) m_mail ;;
      6) m_tz ;;
      7) m_service ;;
      8) m_backup ;;
      0) return 0 ;;
    esac
  done
}

main() {
  local cmd=${1:-menu} f
  case $cmd in
    -h|--help|help) show_banner; usage; return 0 ;;
    -v|--version|version) echo "gnclibre $GNCLIBRE_VERSION"; return 0 ;;
    menu|status|passwd|restart|update|backup|logs|validate) ;;
    *) usage; return 1 ;;
  esac
  need_root "$@"
  touch "$LOG" 2>/dev/null && chmod 600 "$LOG" 2>/dev/null
  command -v docker >/dev/null 2>&1 || die "Docker tidak ditemukan."
  load_env
  case $cmd in
    menu)     ensure_whiptail; TUI=1; main_menu; clear; show_banner; okp "Sampai jumpa." ;;
    status)   show_banner; status_text ;;
    passwd)   ensure_whiptail; TUI=1; do_passwd "${2:-admin}"; local rc=$?; clear; return $rc ;;
    restart)  say "Restart semua container..."; dc restart && wait_web && okp "Web UI siap: $(local_url)" ;;
    update)   do_update ;;
    backup)   say "Backup database..."; if f=$(backup_db); then okp "Backup: $f"; else die "Backup gagal (lihat $LOG)"; fi ;;
    logs)     dc logs -f --tail 100 "${2:-librenms}" ;;
    validate) dc exec -T --user librenms librenms php validate.php ;;
  esac
}

main "$@"
GNCLIBRE_EOF
  chmod 755 /usr/local/bin/gnclibre
  ok "Menu pengelolaan terpasang: ketik 'gnclibre'"
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
  printf '  Kelola         : ketik %sgnclibre%s (ganti password, URL, port, backup, dll)\n' "$C_BLD" "$C_RST"
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
  install_manager
  apply_static_network
  show_summary
  _logfile "===== Instalasi selesai ====="
  finish_network
}

# Semua logika ada di dalam fungsi & main dipanggil di baris terakhir,
# supaya aman dijalankan via "curl ... | bash".
main "$@"; exit $?
