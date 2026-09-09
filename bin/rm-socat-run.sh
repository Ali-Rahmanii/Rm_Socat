#!/usr/bin/env bash
# Exec helper for the rm-socat@.service systemd template. systemd passes the
# instance name (%i, e.g. "rmg1-tcp") as $1; this script looks that rule up
# in ports.conf, builds the matching socat command, and execs it — so the
# process systemd tracks/restarts IS socat itself, not this wrapper.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORTS_CONF="$SCRIPT_DIR/ports.conf"
INSTANCE="${1:-}"

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

[ -n "$INSTANCE" ] || { echo "usage: rm-socat-run.sh <name>-<tcp|udp>" >&2; exit 1; }
[ -f "$PORTS_CONF" ] || { echo "missing $PORTS_CONF" >&2; exit 1; }

PROTO="${INSTANCE##*-}"
NAME="${INSTANCE%-*}"
case "$PROTO" in
  tcp|udp) ;;
  *) echo "instance '$INSTANCE' must end in -tcp or -udp" >&2; exit 1 ;;
esac

FOUND=0
while IFS=',' read -r r_name r_lport r_host r_rport r_proto r_ip; do
  r_name="$(trim "${r_name%%#*}")"
  [ -z "$r_name" ] && continue
  [ "$r_name" = "$NAME" ] || continue
  r_proto="$(trim "$r_proto")"
  [ "$r_proto" = "$PROTO" ] || [ "$r_proto" = "both" ] || continue
  R_LPORT="$(trim "$r_lport")"
  R_HOST="$(trim "$r_host")"
  R_RPORT="$(trim "$r_rport")"
  R_IP="$(trim "${r_ip:-dual}")"
  [ -z "$R_IP" ] && R_IP="dual"
  FOUND=1
  break
done < "$PORTS_CONF"

[ "$FOUND" = 1 ] || { echo "no rule named '$NAME' (proto $PROTO) found in $PORTS_CONF" >&2; exit 1; }

case "$PROTO/$R_IP" in
  tcp/dual) LISTEN="TCP-LISTEN:${R_LPORT},reuseaddr,fork,su=nobody";  TARGET="TCP:${R_HOST}:${R_RPORT}"  ;;
  tcp/4)    LISTEN="TCP4-LISTEN:${R_LPORT},reuseaddr,fork,su=nobody"; TARGET="TCP4:${R_HOST}:${R_RPORT}" ;;
  tcp/6)    LISTEN="TCP6-LISTEN:${R_LPORT},reuseaddr,fork,su=nobody"; TARGET="TCP6:${R_HOST}:${R_RPORT}" ;;
  udp/dual) LISTEN="UDP-LISTEN:${R_LPORT},reuseaddr,fork,su=nobody";  TARGET="UDP:${R_HOST}:${R_RPORT}"  ;;
  udp/4)    LISTEN="UDP4-LISTEN:${R_LPORT},reuseaddr,fork,su=nobody"; TARGET="UDP4:${R_HOST}:${R_RPORT}" ;;
  udp/6)    LISTEN="UDP6-LISTEN:${R_LPORT},reuseaddr,fork,su=nobody"; TARGET="UDP6:${R_HOST}:${R_RPORT}" ;;
  *) echo "unsupported proto/ip combination: $PROTO/$R_IP" >&2; exit 1 ;;
esac

exec /usr/bin/socat "$LISTEN" "$TARGET"
