#!/usr/bin/env bash
# One systemd unit, many forwards. Every rule in ports.conf is hashed to a
# fixed batch (see batches.conf); this script is that batch's whole
# systemd-managed process: it launches every socat this batch owns as a
# background child, and whenever ONE of them dies it respawns just that
# one — instead of dozens of separate systemd units (which is what was
# driving PID 1 / systemd's own CPU usage up when every port got its own
# unit). If this wrapper itself dies, systemd's Restart=always restarts
# the whole batch.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORTS_CONF="$SCRIPT_DIR/ports.conf"
BATCH="${1:-}"

[ -n "$BATCH" ] || { echo "usage: rm-socat-batch-run.sh <batch_id>" >&2; exit 1; }
[ -f "$PORTS_CONF" ] || { echo "missing $PORTS_CONF" >&2; exit 1; }

NUM_BATCHES="$(cat "$SCRIPT_DIR/batches.conf" 2>/dev/null | tr -d '[:space:]')"
[[ "$NUM_BATCHES" =~ ^[0-9]+$ ]] && [ "$NUM_BATCHES" -ge 1 ] || NUM_BATCHES=10

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
bucket_of() { printf '%s' "$1" | cksum | awk -v n="$NUM_BATCHES" '{print $1 % n}'; }

declare -A CMD_LISTEN CMD_TARGET PID_OF

build_socat_args() {  # proto ip lport host rport -> sets LISTEN_ / TARGET_
  local proto="$1" ip="$2" lport="$3" host="$4" rport="$5"
  case "$proto/$ip" in
    tcp/dual) LISTEN_="TCP-LISTEN:${lport},reuseaddr,fork,su=nobody";  TARGET_="TCP:${host}:${rport}"  ;;
    tcp/4)    LISTEN_="TCP4-LISTEN:${lport},reuseaddr,fork,su=nobody"; TARGET_="TCP4:${host}:${rport}" ;;
    tcp/6)    LISTEN_="TCP6-LISTEN:${lport},reuseaddr,fork,su=nobody"; TARGET_="TCP6:${host}:${rport}" ;;
    udp/dual) LISTEN_="UDP-LISTEN:${lport},reuseaddr,fork,su=nobody";  TARGET_="UDP:${host}:${rport}"  ;;
    udp/4)    LISTEN_="UDP4-LISTEN:${lport},reuseaddr,fork,su=nobody"; TARGET_="UDP4:${host}:${rport}" ;;
    udp/6)    LISTEN_="UDP6-LISTEN:${lport},reuseaddr,fork,su=nobody"; TARGET_="UDP6:${host}:${rport}" ;;
    *)        LISTEN_=""; TARGET_="" ;;
  esac
}

load_members() {
  CMD_LISTEN=()
  CMD_TARGET=()
  while IFS=',' read -r n lp h rp pr ip; do
    n="$(trim "${n%%#*}")"
    [ -z "$n" ] && continue
    [ "$(bucket_of "$n")" = "$BATCH" ] || continue
    lp="$(trim "$lp")"; h="$(trim "$h")"; rp="$(trim "$rp")"; pr="$(trim "$pr")"
    ip="$(trim "${ip:-dual}")"; [ -z "$ip" ] && ip=dual
    local protos=()
    case "$pr" in both) protos=(tcp udp) ;; tcp) protos=(tcp) ;; udp) protos=(udp) ;; *) protos=(tcp) ;; esac
    local p
    for p in "${protos[@]}"; do
      build_socat_args "$p" "$ip" "$lp" "$h" "$rp"
      [ -n "$LISTEN_" ] || continue
      CMD_LISTEN["${n}-${p}"]="$LISTEN_"
      CMD_TARGET["${n}-${p}"]="$TARGET_"
    done
  done < "$PORTS_CONF"
}

spawn() {
  local inst="$1"
  socat "${CMD_LISTEN[$inst]}" "${CMD_TARGET[$inst]}" &
  PID_OF["$inst"]=$!
}

SHUTTING_DOWN=0
on_term() {
  SHUTTING_DOWN=1
  local inst
  for inst in "${!PID_OF[@]}"; do
    kill "${PID_OF[$inst]}" 2>/dev/null
  done
  wait 2>/dev/null
  exit 0
}
trap on_term TERM INT

load_members

if [ "${#CMD_LISTEN[@]}" -eq 0 ]; then
  echo "batch $BATCH: no rules assigned, idling." >&2
  while :; do sleep 3600 & wait $!; done
fi

for inst in "${!CMD_LISTEN[@]}"; do
  spawn "$inst"
done

# supervise forever: respawn whichever child just exited
while :; do
  wait -n 2>/dev/null
  [ "$SHUTTING_DOWN" = 1 ] && exit 0
  for inst in "${!PID_OF[@]}"; do
    if ! kill -0 "${PID_OF[$inst]}" 2>/dev/null; then
      spawn "$inst"
    fi
  done
done
