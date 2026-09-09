#!/usr/bin/env bash
# rm-socat — manage TCP/UDP port forwards. Rules live in ports.conf; each
# one is hashed into a fixed batch (batches.conf), and one systemd unit
# supervises every forward in its batch (see bin/rm-socat-batch-run.sh) —
# instead of one systemd unit per port, which is what drove PID 1's own
# CPU usage up once there were dozens of ports. Run with no arguments for
# the interactive menu, or see `./manage.sh help` for direct subcommands.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORTS_CONF="$SCRIPT_DIR/ports.conf"
BATCHES_CONF="$SCRIPT_DIR/batches.conf"

VERSION="v1.1.0"
REPO_URL="https://github.com/Ali-Rahmanii/Rm_Socat"
AUTHOR="Ali Rahmani"
TELEGRAM="@A_Alirahmani"

# ---------------------------------------------------------------- colors --
COLOR_ENABLED=1
[ -n "${NO_COLOR:-}" ] && COLOR_ENABLED=0
[ -t 1 ] || COLOR_ENABLED=0

C_BLUE=$'\033[38;5;69m'
C_CYAN=$'\033[38;5;80m'
C_GREEN=$'\033[38;5;78m'
C_RED=$'\033[38;5;203m'
C_YELLOW=$'\033[38;5;221m'
C_PURPLE=$'\033[38;5;135m'
C_MAGENTA=$'\033[38;5;171m'
C_PINK=$'\033[38;5;212m'
C_GRAY=$'\033[38;5;244m'
C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_DIM=$'\033[2m'

paint() { if [ "$COLOR_ENABLED" = 1 ]; then printf '%s%s%s' "$1" "$2" "$C_RESET"; else printf '%s' "$2"; fi; }
blue()    { paint "$C_BLUE" "$1"; }
cyan()    { paint "$C_CYAN" "$1"; }
green()   { paint "$C_GREEN" "$1"; }
red()     { paint "$C_RED" "$1"; }
yellow()  { paint "$C_YELLOW" "$1"; }
purple()  { paint "$C_PURPLE" "$1"; }
magenta() { paint "$C_MAGENTA" "$1"; }
pink()    { paint "$C_PINK" "$1"; }
gray()    { paint "$C_GRAY" "$1"; }
bold()    { paint "$C_BOLD" "$1"; }
dim()     { paint "$C_DIM" "$1"; }

# top-to-bottom sweep used to color the logo one row at a time
GRADIENT=("$C_BLUE" $'\033[38;5;75m' $'\033[38;5;111m' "$C_PURPLE" "$C_MAGENTA" "$C_PINK")
BORDER_C="$C_PURPLE"
INNER_WIDTH=69

# --------------------------------------------------------------- banner --
# printf '─%.0s' repeated via seq — NOT `tr ' ' '─'`, which mangles a
# multi-byte UTF-8 replacement char in byte-oriented locales/tr builds.
RULE="$(printf -- '─%.0s' $(seq 1 "$INNER_WIDTH"))"

hline() { printf '%s\n' "$(paint "$BORDER_C" "${1}${RULE}${2}")"; }

box_text() {
  local text="$1" code="${2:-}" plainlen=${#1} pad left right body
  pad=$(( INNER_WIDTH - plainlen )); (( pad < 0 )) && pad=0
  left=$(( pad / 2 )); right=$(( pad - left ))
  body="$text"
  [ -n "$code" ] && [ "$COLOR_ENABLED" = 1 ] && body="${code}${text}${C_RESET}"
  printf '%s%*s%s%*s%s\n' "$(paint "$BORDER_C" '│')" "$left" '' "$body" "$right" '' "$(paint "$BORDER_C" '│')"
}

banner() {
  [ "$COLOR_ENABLED" = 1 ] && printf '\033[H\033[2J'
  local logo=(
    '██████╗ ███╗   ███╗      ███████╗ ██████╗  ██████╗ █████╗ ████████╗'
    '██╔══██╗████╗ ████║      ██╔════╝██╔═══██╗██╔════╝██╔══██╗╚══██╔══╝'
    '██████╔╝██╔████╔██║█████╗███████╗██║   ██║██║     ███████║   ██║   '
    '██╔══██╗██║╚██╔╝██║╚════╝╚════██║██║   ██║██║     ██╔══██║   ██║   '
    '██║  ██║██║ ╚═╝ ██║      ███████║╚██████╔╝╚██████╗██║  ██║   ██║   '
    '╚═╝  ╚═╝╚═╝     ╚═╝      ╚══════╝ ╚═════╝  ╚═════╝╚═╝  ╚═╝   ╚═╝   '
  )
  echo
  hline '┌' '┐'
  local i
  for i in "${!logo[@]}"; do
    box_text "${logo[$i]}" "${GRADIENT[$i]}"
  done
  box_text "TCP/UDP port forwarder over socat + systemd" "$C_GRAY"
  hline '├' '┤'
  box_text "$VERSION" "$C_GREEN"
  box_text "$REPO_URL" "$C_GRAY"
  box_text "by ${AUTHOR}  ·  Telegram: ${TELEGRAM}" "$C_PINK"
  hline '└' '┘'
  echo
}

# ----------------------------------------------------------------- utils --
log()  { printf '%s %s\n' "$(green '==>')" "$1"; }
warn() { printf '%s %s\n' "$(yellow '!!')" "$1" >&2; }
die()  { printf '%s %s\n' "$(red 'error:')" "$1" >&2; exit 1; }

require_root() { [ "$(id -u)" = 0 ] || die "this needs root — run with sudo (sudo ./manage.sh ...)"; }

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
      log "created ports.conf from the example: $PORTS_CONF"
    else
      : > "$PORTS_CONF"
    fi
  fi
  [ -f "$BATCHES_CONF" ] || echo 10 > "$BATCHES_CONF"
}

load_num_batches() {
  NUM_BATCHES="$(cat "$BATCHES_CONF" 2>/dev/null | tr -d '[:space:]')"
  [[ "$NUM_BATCHES" =~ ^[0-9]+$ ]] && [ "$NUM_BATCHES" -ge 1 ] || NUM_BATCHES=10
}

# which fixed batch a rule's name hashes into — stable regardless of how
# many other rules exist, so adding/removing one rule never reshuffles
# anyone else's batch
bucket_of() { printf '%s' "$1" | cksum | awk -v n="$NUM_BATCHES" '{print $1 % n}'; }

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

desired_instance_count() { desired_instances | wc -l | tr -d '[:space:]'; }

check_conflict() {
  local new_name="$1" new_port="$2" new_proto="$3"
  while IFS=',' read -r n lp h rp pr ip; do
    n="$(trim "${n%%#*}")"
    [ -z "$n" ] && continue
    [ "$n" = "$new_name" ] && continue
    lp="$(trim "$lp")"; pr="$(trim "$pr")"
    if [ "$lp" = "$new_port" ]; then
      if [ "$pr" = both ] || [ "$new_proto" = both ] || [ "$pr" = "$new_proto" ]; then
        die "port $new_port/$new_proto conflicts with existing rule '$n'."
      fi
    fi
  done < "$PORTS_CONF"
}

install_unit_template() {
  sed "s#__RUN_HELPER__#${SCRIPT_DIR}/bin/rm-socat-batch-run.sh#" "$SCRIPT_DIR/systemd/rm-socat-batch@.service" > /etc/systemd/system/rm-socat-batch@.service
  systemctl daemon-reload
}

# stop/disable leftover units from the old one-unit-per-port scheme
migrate_legacy_units() {
  local legacy
  legacy="$(systemctl list-unit-files 'rm-socat@*' --no-legend 2>/dev/null | awk '{print $1}')"
  [ -z "$legacy" ] && return 0
  log "removing old one-unit-per-port services..."
  while IFS= read -r u; do
    [ -z "$u" ] && continue
    systemctl disable --now "$u" >/dev/null 2>&1 || true
  done <<< "$legacy"
  rm -f /etc/systemd/system/rm-socat@.service
  systemctl daemon-reload
}

# ------------------------------------------------------------- commands --
cmd_add() {
  require_root
  ensure_conf
  load_num_batches
  local name lport host rport proto ip
  if [ $# -ge 4 ]; then
    name="$1"; lport="$2"; host="$3"; rport="$4"; proto="${5:-both}"; ip="${6:-dual}"
  else
    echo "$(bold 'Add a new forward rule')"
    read -r -p "  name (unique, letters/digits/-/_ only): " name
    read -r -p "  local port (what users connect to on this box): " lport
    read -r -p "  remote domain or IP: " host
    read -r -p "  remote port: " rport
    read -r -p "  protocol [tcp/udp/both] (default both): " proto
    proto="${proto:-both}"
    read -r -p "  IP version [dual/4/6] (default dual): " ip
    ip="${ip:-dual}"
  fi

  [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || die "invalid name (letters/digits/-/_ only)."
  grep -Eq "^[[:space:]]*${name}[[:space:]]*," "$PORTS_CONF" 2>/dev/null && die "a rule named '$name' already exists."
  [[ "$lport" =~ ^[0-9]+$ ]] && [ "$lport" -ge 1 ] && [ "$lport" -le 65535 ] || die "invalid local port (1-65535)."
  [[ "$rport" =~ ^[0-9]+$ ]] && [ "$rport" -ge 1 ] && [ "$rport" -le 65535 ] || die "invalid remote port (1-65535)."
  [ -n "$host" ] || die "remote domain/IP can't be empty."
  case "$proto" in tcp|udp|both) ;; *) die "protocol must be tcp, udp, or both." ;; esac
  case "$ip" in dual|4|6) ;; *) die "IP version must be dual, 4, or 6." ;; esac

  check_conflict "$name" "$lport" "$proto"

  printf '%s , %s , %s , %s , %s , %s\n' "$name" "$lport" "$host" "$rport" "$proto" "$ip" >> "$PORTS_CONF"
  log "rule '$name' added to ports.conf."

  local b; b="$(bucket_of "$name")"
  systemctl enable --now "rm-socat-batch@${b}.service" >/dev/null 2>&1
  systemctl restart "rm-socat-batch@${b}.service"
  echo "  $(green '✓') batch ${b} restarted to pick up '${name}' (other rules sharing that batch blip too)"
}

cmd_remove() {
  require_root
  ensure_conf
  load_num_batches
  local name="${1:-}"
  [ -n "$name" ] || die "usage: manage.sh remove <name>"
  [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || die "invalid name (letters/digits/-/_ only)."

  if grep -Eq "^[[:space:]]*${name}[[:space:]]*," "$PORTS_CONF" 2>/dev/null; then
    local b; b="$(bucket_of "$name")"
    sed -i "/^[[:space:]]*${name}[[:space:]]*,/d" "$PORTS_CONF"
    systemctl restart "rm-socat-batch@${b}.service" 2>/dev/null || true
    log "rule '$name' removed; batch ${b} restarted."
  else
    warn "no rule named '$name' in ports.conf — nothing to remove."
  fi
}

cmd_apply() {
  require_root
  ensure_conf
  load_num_batches
  migrate_legacy_units

  log "applying ports.conf across $NUM_BATCHES batch(es)..."
  local b
  for ((b = 0; b < NUM_BATCHES; b++)); do
    systemctl enable --now "rm-socat-batch@${b}.service" >/dev/null 2>&1
    systemctl restart "rm-socat-batch@${b}.service"
    if systemctl is-active --quiet "rm-socat-batch@${b}.service"; then
      echo "  $(green '✓') rm-socat-batch@${b}"
    else
      echo "  $(red '✗') rm-socat-batch@${b} $(dim "(failed — see: journalctl -u rm-socat-batch@${b})")"
    fi
  done

  # drop batch units left over from a higher batch count set previously
  local existing
  existing="$( { systemctl list-units 'rm-socat-batch@*' --all --no-legend --plain 2>/dev/null | awk '{print $1}';
                 systemctl list-unit-files 'rm-socat-batch@*' --no-legend 2>/dev/null | awk '{print $1}'; } | sort -u)"
  while IFS= read -r unit; do
    [ -z "$unit" ] && continue
    local id="${unit#rm-socat-batch@}"; id="${id%.service}"
    if [[ "$id" =~ ^[0-9]+$ ]] && [ "$id" -ge "$NUM_BATCHES" ]; then
      systemctl disable --now "$unit" >/dev/null 2>&1 || true
      echo "  $(red '✗ removed') $unit (beyond current batch count)"
    fi
  done <<< "$existing"

  log "done."
}

cmd_status() {
  ensure_conf
  load_num_batches
  printf "%-16s %-6s %-8s %-28s %-16s %-8s\n" "NAME" "PROTO" "PORT" "TARGET" "BATCH" "SOCKET"
  while IFS=',' read -r n lp h rp pr ip; do
    n="$(trim "${n%%#*}")"
    [ -z "$n" ] && continue
    lp="$(trim "$lp")"; h="$(trim "$h")"; rp="$(trim "$rp")"; pr="$(trim "$pr")"
    local b; b="$(bucket_of "$n")"
    local protos=()
    case "$pr" in both) protos=(tcp udp) ;; tcp) protos=(tcp) ;; udp) protos=(udp) ;; esac
    for p in "${protos[@]}"; do
      local unit="rm-socat-batch@${b}.service" active sockstr batchstr
      if systemctl is-active --quiet "$unit" 2>/dev/null; then active="$(green active)"; else active="$(red down)"; fi
      batchstr="batch${b}:${active}"
      if [ "$p" = tcp ]; then
        ss -Htln "sport = :${lp}" 2>/dev/null | grep -q LISTEN && sockstr="$(green LISTEN)" || sockstr="$(red CLOSED)"
      else
        ss -Huan "sport = :${lp}" 2>/dev/null | grep -q . && sockstr="$(green LISTEN)" || sockstr="$(red CLOSED)"
      fi
      printf "%-16s %-6s %-8s %-28s %-16s %-8s\n" "$n" "$p" "$lp" "${h}:${rp}" "$batchstr" "$sockstr"
    done
  done < "$PORTS_CONF"
}

cmd_restart() {
  require_root
  load_num_batches
  local b
  for ((b = 0; b < NUM_BATCHES; b++)); do
    systemctl restart "rm-socat-batch@${b}.service"
    echo "  $(green '✓ restarted') rm-socat-batch@${b}"
  done
}

cmd_test() { "$SCRIPT_DIR/tests/test_ports.sh" "$@"; }

cmd_stress() {
  echo "$(yellow 'warning:') this puts real load on the full forward chain (up to the actual remote server), not just the local socket."
  confirm "continue?" false || { echo "cancelled."; return 0; }
  "$SCRIPT_DIR/tests/stress_test.sh" "$@"
}

cmd_batches() {
  require_root
  ensure_conf
  load_num_batches
  local total; total="$(desired_instance_count)"
  echo "current batch count: $NUM_BATCHES  (about $total forwards configured, ~$(( (total + NUM_BATCHES - 1) / NUM_BATCHES )) per batch on average)"
  read -r -p "new batch count (fewer units = less systemd overhead, each restart affects more ports): " n
  [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] || die "must be a positive integer."
  echo "$n" > "$BATCHES_CONF"
  log "batch count set to $n — applying..."
  cmd_apply
}

cmd_update() {
  require_root
  [ -d "$SCRIPT_DIR/.git" ] || die "not a git checkout — reinstall with the one-line installer (see README) to enable updates."
  log "pulling latest changes..."
  # any local drift in tracked files (an old chmod, a manual edit) would
  # otherwise make `git pull --ff-only` refuse outright — stash it out of
  # the way first and restore it after, so update never gets stuck
  local stashed=0
  if [ -n "$(git -C "$SCRIPT_DIR" status --porcelain 2>/dev/null)" ]; then
    log "stashing local changes before pulling..."
    git -C "$SCRIPT_DIR" stash push -u -m "rm-socat auto-stash before update" >/dev/null 2>&1 && stashed=1
  fi
  if ! git -C "$SCRIPT_DIR" pull --ff-only; then
    [ "$stashed" = 1 ] && git -C "$SCRIPT_DIR" stash pop >/dev/null 2>&1
    die "git pull failed even after stashing local changes — check $SCRIPT_DIR manually (git status / git log)"
  fi
  if [ "$stashed" = 1 ] && ! git -C "$SCRIPT_DIR" stash pop >/dev/null 2>&1; then
    warn "pulled fine, but couldn't reapply your local changes automatically — run: git -C $SCRIPT_DIR stash list"
  fi
  chmod +x "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/bin/*.sh "$SCRIPT_DIR"/tests/*.sh 2>/dev/null || true
  log "reinstalling the systemd template (in case it changed)..."
  install_unit_template
  cat > /usr/local/bin/rmsocat <<EOF
#!/usr/bin/env bash
exec "${SCRIPT_DIR}/manage.sh" "\$@"
EOF
  chmod +x /usr/local/bin/rmsocat
  ensure_conf
  cmd_apply
  log "update complete."
}

cmd_purge() {
  require_root
  warn "this stops and completely removes every forward from the system (systemd, kernel tuning, and finally this whole directory)."
  confirm "continue?" false || { echo "cancelled."; return 0; }

  local units
  units="$( { systemctl list-units 'rm-socat-batch@*' 'rm-socat@*' --all --no-legend --plain 2>/dev/null | awk '{print $1}';
              systemctl list-unit-files 'rm-socat-batch@*' 'rm-socat@*' --no-legend 2>/dev/null | awk '{print $1}'; } | sort -u)"
  while IFS= read -r unit; do
    [ -z "$unit" ] && continue
    if systemctl stop "$unit" >/dev/null 2>&1 && systemctl disable "$unit" >/dev/null 2>&1; then
      echo "  $(red '✗ stopped') $unit"
    else
      echo "  $(yellow '?? could not stop/disable') $unit $(dim '(removing its unit file directly instead)')"
    fi
  done <<< "$units"

  # belt-and-suspenders: some of the above can silently fail under load
  # (dozens of units stopping at once) — remove the template files and any
  # leftover enablement symlinks/overrides directly so nothing survives a
  # partial failure, then flush systemd's own memory of them.
  rm -f /etc/systemd/system/rm-socat@.service /etc/systemd/system/rm-socat-batch@.service
  rm -f /etc/systemd/system/multi-user.target.wants/rm-socat@*.service
  rm -f /etc/systemd/system/multi-user.target.wants/rm-socat-batch@*.service
  rm -rf /etc/systemd/system/rm-socat@*.service.d /etc/systemd/system/rm-socat-batch@*.service.d
  systemctl daemon-reload
  systemctl reset-failed >/dev/null 2>&1 || true

  # last resort: any socat process that somehow survived the unit stops
  pkill -x socat >/dev/null 2>&1 || true

  rm -f /etc/sysctl.d/99-rm-socat.conf /etc/security/limits.d/99-rm-socat.conf
  sysctl --system >/dev/null 2>&1 || true
  rm -f /usr/local/bin/rmsocat
  log "all services, the rmsocat command, and system-wide tuning removed."

  echo "$(bold 'verify:') systemctl list-units 'rm-socat*' --all   and   ps aux | grep socat"

  echo
  read -r -p "$(yellow 'type YES to also delete this entire project directory (ports.conf and every script included): ')" ans
  if [ "$ans" = "YES" ]; then
    cd /
    rm -rf "$SCRIPT_DIR"
    echo "fully cleaned up — nothing left behind."
  else
    echo "systemd units and kernel tuning removed; the project directory (ports.conf and scripts) was kept."
  fi
}

print_help() {
  cat <<EOF
$(bold "rm-socat manage.sh") $(dim "$VERSION")
$(dim "(after install.sh, the 'rmsocat' command runs this from anywhere)")

  ./manage.sh                          interactive menu
  ./manage.sh add [name lport host rport [proto] [ip]]
  ./manage.sh remove <name>
  ./manage.sh apply                    sync systemd with ports.conf
  ./manage.sh status                   live status of every port
  ./manage.sh restart                  restart every batch
  ./manage.sh test                     confirm every port is actually open
  ./manage.sh stress <port> [tcp|udp] [step] [hold] [max]
  ./manage.sh batches                  change how many systemd units share the load
  ./manage.sh update                   git pull + re-apply
  ./manage.sh purge                    full uninstall
EOF
}

# --------------------------------------------------------------- menu ---
menu_item() { printf '  %s %s   %s\n' "$(gray '❯')" "$(pink "[$1]")" "$2"; }
hline_plain() { printf '%s\n' "$(blue "$RULE")"; }

menu() {
  while true; do
    banner
    echo " $(bold "$(purple 'Main Menu')")"
    hline_plain
    menu_item 1  "Add a new port forward"
    menu_item 2  "Remove a port forward"
    menu_item 3  "Apply ports.conf changes"
    menu_item 4  "Live status of all ports"
    menu_item 5  "Restart everything"
    menu_item 6  "Test port health"
    menu_item 7  "Stress test / max connections"
    menu_item 8  "Edit ports.conf manually"
    menu_item 9  "Change batch count (systemd units)"
    menu_item 10 "Update rm-socat (git pull + re-apply)"
    menu_item 11 "Full uninstall (purge)"
    menu_item 0  "Exit"
    hline_plain
    echo
    read -r -p "$(bold "$(purple 'choice')") $(purple '❯') " choice
    echo
    case "$choice" in
      1) cmd_add ;;
      2) read -r -p "rule name to remove: " n; cmd_remove "$n" ;;
      3) cmd_apply ;;
      4) cmd_status ;;
      5) cmd_restart ;;
      6) cmd_test ;;
      7)
        read -r -p "local port: " p_port
        read -r -p "protocol [tcp/udp] (default tcp): " p_proto; p_proto="${p_proto:-tcp}"
        cmd_stress "$p_port" "$p_proto"
        ;;
      8) "${EDITOR:-nano}" "$PORTS_CONF" ;;
      9) cmd_batches ;;
      10) cmd_update ;;
      11) cmd_purge; exit 0 ;;
      0) echo "$(dim 'bye.')"; exit 0 ;;
      *) warn "invalid choice" ;;
    esac
    echo
    read -r -p "$(dim 'press Enter to continue...')" _
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
  batches) cmd_batches ;;
  update)  cmd_update ;;
  purge)   cmd_purge ;;
  menu)    menu ;;
  help|-h|--help) print_help ;;
  *) die "invalid command: ${1:-} — see: ./manage.sh help" ;;
esac
