#!/usr/bin/env bash
# rm-socat — manage TCP/UDP port forwards (socat + systemd, one dual-stack
# socket per rule). Run with no arguments for the interactive menu, or see
# `./manage.sh help` for direct subcommands.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORTS_CONF="$SCRIPT_DIR/ports.conf"

# ---------------------------------------------------------------- colors --
COLOR_ENABLED=1
[ -n "${NO_COLOR:-}" ] && COLOR_ENABLED=0
[ -t 1 ] || COLOR_ENABLED=0

paint() { if [ "$COLOR_ENABLED" = 1 ]; then printf '%s%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi; }
blue()    { paint $'\033[38;5;69m'  "$1"; }
cyan()    { paint $'\033[38;5;80m'  "$1"; }
green()   { paint $'\033[38;5;78m'  "$1"; }
red()     { paint $'\033[38;5;203m' "$1"; }
yellow()  { paint $'\033[38;5;221m' "$1"; }
magenta() { paint $'\033[38;5;171m' "$1"; }
pink()    { paint $'\033[38;5;212m' "$1"; }
gray()    { paint $'\033[38;5;244m' "$1"; }
bold()    { paint $'\033[1m' "$1"; }
dim()     { paint $'\033[2m' "$1"; }

GRADIENT=($'\033[38;5;69m' $'\033[38;5;75m' $'\033[38;5;111m' $'\033[38;5;135m' $'\033[38;5;171m' $'\033[38;5;212m')
gradient_text() {
  local s="$1"
  if [ "$COLOR_ENABLED" != 1 ]; then printf '%s' "$s"; return; fi
  local n=${#GRADIENT[@]} len=${#s} i out=""
  for ((i = 0; i < len; i++)); do
    out+="${GRADIENT[$((i % n))]}${s:i:1}"
  done
  printf '%s\033[0m' "$out"
}

banner() {
  [ "$COLOR_ENABLED" = 1 ] && printf '\033[H\033[2J'
  echo
  echo "  $(gradient_text 'RM-SOCAT')  $(dim '— TCP/UDP port forwarder over socat + systemd')"
  echo
}

# ----------------------------------------------------------------- utils --
log()  { printf '%s %s\n' "$(green '==>')" "$1"; }
warn() { printf '%s %s\n' "$(yellow '!!')" "$1" >&2; }
die()  { printf '%s %s\n' "$(red 'error:')" "$1" >&2; exit 1; }

require_root() { [ "$(id -u)" = 0 ] || die "این عملیات نیاز به root دارد (sudo ./manage.sh ...)"; }

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

confirm() {
  local prompt="$1" def="${2:-false}" hint ans
  hint="y/N"; [ "$def" = true ] && hint="Y/n"
  read -r -p "$prompt ($hint): " ans
  ans="$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')"
  if [ -z "$ans" ]; then [ "$def" = true ]; return; fi
  [ "$ans" = y ] || [ "$ans" = yes ]
}

ensure_conf() {
  if [ ! -f "$PORTS_CONF" ]; then
    if [ -f "$SCRIPT_DIR/ports.conf.example" ]; then
      cp "$SCRIPT_DIR/ports.conf.example" "$PORTS_CONF"
      log "ports.conf از روی نمونه ساخته شد: $PORTS_CONF"
    else
      : > "$PORTS_CONF"
    fi
  fi
}

# instances (name-tcp / name-udp) that ports.conf currently asks for
desired_instances() {
  while IFS=',' read -r n lp h rp pr ip; do
    n="$(trim "${n%%#*}")"
    [ -z "$n" ] && continue
    pr="$(trim "$pr")"
    case "$pr" in
      both) printf '%s-tcp\n%s-udp\n' "$n" "$n" ;;
      tcp)  printf '%s-tcp\n' "$n" ;;
      udp)  printf '%s-udp\n' "$n" ;;
    esac
  done < "$PORTS_CONF"
}

check_conflict() {
  local new_name="$1" new_port="$2" new_proto="$3"
  while IFS=',' read -r n lp h rp pr ip; do
    n="$(trim "${n%%#*}")"
    [ -z "$n" ] && continue
    [ "$n" = "$new_name" ] && continue
    lp="$(trim "$lp")"; pr="$(trim "$pr")"
    if [ "$lp" = "$new_port" ]; then
      if [ "$pr" = both ] || [ "$new_proto" = both ] || [ "$pr" = "$new_proto" ]; then
        die "پورت $new_port/$new_proto با قانون موجود '$n' تداخل دارد."
      fi
    fi
  done < "$PORTS_CONF"
}

# ------------------------------------------------------------- commands --
cmd_add() {
  ensure_conf
  local name lport host rport proto ip
  if [ $# -ge 4 ]; then
    name="$1"; lport="$2"; host="$3"; rport="$4"; proto="${5:-both}"; ip="${6:-dual}"
  else
    echo "$(bold 'افزودن قانون فوروارد جدید')"
    read -r -p "  نام (یکتا، فقط حروف/عدد/-/_): " name
    read -r -p "  پورت ورودی روی این سرور: " lport
    read -r -p "  دامنه یا آی‌پی مقصد: " host
    read -r -p "  پورت روی مقصد: " rport
    read -r -p "  پروتکل [tcp/udp/both] (پیش‌فرض both): " proto
    proto="${proto:-both}"
    read -r -p "  نسخه IP [dual/4/6] (پیش‌فرض dual): " ip
    ip="${ip:-dual}"
  fi

  [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || die "نام نامعتبر است (فقط حروف/عدد/-/_)."
  grep -Eq "^[[:space:]]*${name}[[:space:]]*," "$PORTS_CONF" 2>/dev/null && die "نامی به این اسم قبلاً وجود دارد."
  [[ "$lport" =~ ^[0-9]+$ ]] && [ "$lport" -ge 1 ] && [ "$lport" -le 65535 ] || die "پورت ورودی نامعتبر است (1-65535)."
  [[ "$rport" =~ ^[0-9]+$ ]] && [ "$rport" -ge 1 ] && [ "$rport" -le 65535 ] || die "پورت مقصد نامعتبر است (1-65535)."
  [ -n "$host" ] || die "دامنه/آی‌پی مقصد خالی است."
  case "$proto" in tcp|udp|both) ;; *) die "پروتکل باید tcp یا udp یا both باشد." ;; esac
  case "$ip" in dual|4|6) ;; *) die "نسخه IP باید dual یا 4 یا 6 باشد." ;; esac

  check_conflict "$name" "$lport" "$proto"

  printf '%s , %s , %s , %s , %s , %s\n' "$name" "$lport" "$host" "$rport" "$proto" "$ip" >> "$PORTS_CONF"
  log "قانون '$name' به ports.conf اضافه شد."
  sync_rule "$name"
}

sync_rule() {
  require_root
  local name="$1" proto
  proto="$(awk -F',' -v n="$name" '{ gsub(/^[ \t]+|[ \t]+$/,"",$1); if ($1==n) { gsub(/^[ \t]+|[ \t]+$/,"",$5); print $5; exit } }' "$PORTS_CONF")"
  [ -n "$proto" ] || die "قانون '$name' در ports.conf پیدا نشد."
  local protos=()
  case "$proto" in both) protos=(tcp udp) ;; tcp) protos=(tcp) ;; udp) protos=(udp) ;; esac
  for p in "${protos[@]}"; do
    systemctl enable --now "rm-socat@${name}-${p}.service"
    echo "  $(green '✓') rm-socat@${name}-${p} فعال شد"
  done
}

cmd_remove() {
  require_root
  local name="${1:-}"
  [ -n "$name" ] || die "استفاده: manage.sh remove <name>"
  [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || die "نام نامعتبر است (فقط حروف/عدد/-/_)."
  for p in tcp udp; do
    systemctl disable --now "rm-socat@${name}-${p}.service" >/dev/null 2>&1 || true
  done
  ensure_conf
  if grep -Eq "^[[:space:]]*${name}[[:space:]]*," "$PORTS_CONF" 2>/dev/null; then
    sed -i "/^[[:space:]]*${name}[[:space:]]*,/d" "$PORTS_CONF"
    log "قانون '$name' حذف و سرویس‌هایش متوقف/غیرفعال شدند."
  else
    warn "قانونی به اسم '$name' در ports.conf نبود — فقط سرویس‌های احتمالی متوقف شدند."
  fi
}

cmd_apply() {
  require_root
  ensure_conf
  log "اعمال ports.conf روی systemd..."
  mapfile -t desired < <(desired_instances)

  for inst in "${desired[@]}"; do
    systemctl enable --now "rm-socat@${inst}.service" >/dev/null 2>&1
    systemctl restart "rm-socat@${inst}.service"
    if systemctl is-active --quiet "rm-socat@${inst}.service"; then
      echo "  $(green '✓') rm-socat@${inst}"
    else
      echo "  $(red '✗') rm-socat@${inst} $(dim '(بالا نیامد — journalctl -u rm-socat@'"${inst}"' را ببین)')"
    fi
  done

  local existing
  existing="$( { systemctl list-units 'rm-socat@*' --all --no-legend --plain 2>/dev/null | awk '{print $1}';
                 systemctl list-unit-files 'rm-socat@*' --no-legend 2>/dev/null | awk '{print $1}'; } | sort -u)"
  while IFS= read -r unit; do
    [ -z "$unit" ] && continue
    local inst="${unit#rm-socat@}"; inst="${inst%.service}"
    local keep=0 d
    for d in "${desired[@]}"; do [ "$d" = "$inst" ] && keep=1 && break; done
    if [ "$keep" -eq 0 ]; then
      systemctl disable --now "$unit" >/dev/null 2>&1 || true
      echo "  $(red '✗ removed stale') $unit"
    fi
  done <<< "$existing"

  log "اعمال شد."
}

cmd_status() {
  ensure_conf
  printf "%-16s %-6s %-8s %-28s %-10s %-8s\n" "NAME" "PROTO" "PORT" "TARGET" "SYSTEMD" "SOCKET"
  while IFS=',' read -r n lp h rp pr ip; do
    n="$(trim "${n%%#*}")"
    [ -z "$n" ] && continue
    lp="$(trim "$lp")"; h="$(trim "$h")"; rp="$(trim "$rp")"; pr="$(trim "$pr")"
    local protos=()
    case "$pr" in both) protos=(tcp udp) ;; tcp) protos=(tcp) ;; udp) protos=(udp) ;; esac
    for p in "${protos[@]}"; do
      local unit="rm-socat@${n}-${p}.service" active sockstr
      if systemctl is-active --quiet "$unit" 2>/dev/null; then active="$(green active)"; else active="$(red down)"; fi
      if [ "$p" = tcp ]; then
        ss -Htln "sport = :${lp}" 2>/dev/null | grep -q LISTEN && sockstr="$(green LISTEN)" || sockstr="$(red CLOSED)"
      else
        ss -Huln "sport = :${lp}" 2>/dev/null | grep -q . && sockstr="$(green LISTEN)" || sockstr="$(red CLOSED)"
      fi
      printf "%-16s %-6s %-8s %-28s %-10s %-8s\n" "$n" "$p" "$lp" "${h}:${rp}" "$active" "$sockstr"
    done
  done < "$PORTS_CONF"
}

cmd_restart() {
  require_root
  ensure_conf
  mapfile -t desired < <(desired_instances)
  for inst in "${desired[@]}"; do
    systemctl restart "rm-socat@${inst}.service"
    echo "  $(green '✓ restarted') rm-socat@${inst}"
  done
}

cmd_test() { "$SCRIPT_DIR/tests/test_ports.sh" "$@"; }

cmd_stress() {
  echo "$(yellow 'هشدار:') این تست کل زنجیره‌ی فوروارد (تا سرور مقصد واقعی) رو زیر فشار می‌ذاره، نه فقط سوکت لوکال."
  confirm "ادامه بدم؟" false || { echo "لغو شد."; return 0; }
  "$SCRIPT_DIR/tests/stress_test.sh" "$@"
}

cmd_purge() {
  require_root
  warn "این کار همه‌ی فورواردها رو متوقف و کاملاً از سیستم حذف می‌کنه (systemd، تنظیمات کرنل، و در آخر خودِ این پوشه)."
  confirm "ادامه بده؟" false || { echo "لغو شد."; return 0; }

  local units
  units="$( { systemctl list-units 'rm-socat@*' --all --no-legend --plain 2>/dev/null | awk '{print $1}';
              systemctl list-unit-files 'rm-socat@*' --no-legend 2>/dev/null | awk '{print $1}'; } | sort -u)"
  while IFS= read -r unit; do
    [ -z "$unit" ] && continue
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
    echo "  $(red '✗ stopped') $unit"
  done <<< "$units"

  rm -f /etc/systemd/system/rm-socat@.service
  systemctl daemon-reload
  rm -f /etc/sysctl.d/99-rm-socat.conf /etc/security/limits.d/99-rm-socat.conf
  sysctl --system >/dev/null 2>&1 || true
  log "همه‌ی سرویس‌ها و تنظیمات سیستمی پاک شدند."

  echo
  read -r -p "$(yellow 'برای حذف کامل پوشه‌ی پروژه (شامل ports.conf و خود اسکریپت‌ها) بنویس YES: ')" ans
  if [ "$ans" = "YES" ]; then
    cd /
    rm -rf "$SCRIPT_DIR"
    echo "پاکسازی کامل انجام شد — چیزی باقی نماند."
  else
    echo "systemd و تنظیمات کرنل پاک شدند؛ پوشه‌ی پروژه (ports.conf و اسکریپت‌ها) نگه داشته شد."
  fi
}

print_help() {
  cat <<EOF
$(bold 'rm-socat manage.sh')

  ./manage.sh                          منوی تعاملی
  ./manage.sh add [name lport host rport [proto] [ip]]
  ./manage.sh remove <name>
  ./manage.sh apply                    هماهنگ کردن systemd با ports.conf
  ./manage.sh status                   وضعیت زنده‌ی همه‌ی پورت‌ها
  ./manage.sh restart                  ری‌استارت همه‌ی فورواردها
  ./manage.sh test                     تست باز بودن همه‌ی پورت‌ها
  ./manage.sh stress <port> [tcp|udp] [step] [hold] [max]
  ./manage.sh purge                    پاکسازی کامل (uninstall)
EOF
}

# --------------------------------------------------------------- menu ---
menu() {
  while true; do
    banner
    echo "  1) $(cyan 'افزودن پورت فوروارد جدید')"
    echo "  2) $(cyan 'حذف یک پورت فوروارد')"
    echo "  3) $(cyan 'اعمال تغییرات ports.conf (apply)')"
    echo "  4) $(cyan 'وضعیت زنده‌ی همه‌ی پورت‌ها')"
    echo "  5) $(cyan 'ری‌استارت همه')"
    echo "  6) $(cyan 'تست سلامت پورت‌ها')"
    echo "  7) $(magenta 'تست فشار / حداکثر کانکشن')"
    echo "  8) $(pink 'ویرایش دستی ports.conf')"
    echo "  9) $(red 'پاکسازی کامل (uninstall)')"
    echo "  0) خروج"
    echo
    read -r -p "$(bold 'انتخاب: ')" choice
    echo
    case "$choice" in
      1) cmd_add ;;
      2) read -r -p "نام قانون برای حذف: " n; cmd_remove "$n" ;;
      3) cmd_apply ;;
      4) cmd_status ;;
      5) cmd_restart ;;
      6) cmd_test ;;
      7)
        read -r -p "پورت محلی: " p_port
        read -r -p "پروتکل [tcp/udp] (پیش‌فرض tcp): " p_proto; p_proto="${p_proto:-tcp}"
        cmd_stress "$p_port" "$p_proto"
        ;;
      8) "${EDITOR:-nano}" "$PORTS_CONF" ;;
      9) cmd_purge; exit 0 ;;
      0) exit 0 ;;
      *) warn "گزینه نامعتبر" ;;
    esac
    echo
    read -r -p "$(dim 'برای ادامه Enter بزن...')" _
  done
}

# --------------------------------------------------------------- main ---
ensure_conf

case "${1:-menu}" in
  add)     shift; cmd_add "$@" ;;
  remove)  shift; cmd_remove "$@" ;;
  apply)   cmd_apply ;;
  status)  cmd_status ;;
  restart) cmd_restart ;;
  test)    shift; cmd_test "$@" ;;
  stress)  shift; cmd_stress "$@" ;;
  purge)   cmd_purge ;;
  menu)    menu ;;
  help|-h|--help) print_help ;;
  *) die "دستور نامعتبر: ${1:-} — برای راهنما: ./manage.sh help" ;;
esac
