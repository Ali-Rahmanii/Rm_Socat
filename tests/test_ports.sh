#!/usr/bin/env bash
# Health check: does every port listed in ports.conf actually have a
# listening socket right now? No files written, output only.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORTS_CONF="$SCRIPT_DIR/ports.conf"
[ -f "$PORTS_CONF" ] || { echo "ports.conf not found: $PORTS_CONF" >&2; exit 1; }

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

pass=0
fail=0
while IFS=',' read -r n lp h rp pr ip; do
  n="$(trim "${n%%#*}")"
  [ -z "$n" ] && continue
  lp="$(trim "$lp")"; pr="$(trim "$pr")"

  protos=()
  case "$pr" in
    both) protos=(tcp udp) ;;
    tcp)  protos=(tcp) ;;
    udp)  protos=(udp) ;;
    *)    protos=(tcp) ;;
  esac

  for p in "${protos[@]}"; do
    if [ "$p" = tcp ]; then
      if ss -Htln "sport = :${lp}" 2>/dev/null | grep -q LISTEN; then
        printf '\033[38;5;78m✅\033[0m %-16s tcp  :%-7s LISTEN\n' "$n" "$lp"; pass=$((pass + 1))
      else
        printf '\033[38;5;203m❌\033[0m %-16s tcp  :%-7s CLOSED\n' "$n" "$lp"; fail=$((fail + 1))
      fi
    else
      # -a, not -l: some iproute2 builds don't reliably flag a bound UDP
      # socket as "listening" since UDP has no LISTEN state to begin with
      # (it shows UNCONN) — -a lists it regardless of that heuristic.
      if ss -Huan "sport = :${lp}" 2>/dev/null | grep -q .; then
        printf '\033[38;5;78m✅\033[0m %-16s udp  :%-7s LISTEN\n' "$n" "$lp"; pass=$((pass + 1))
      else
        printf '\033[38;5;203m❌\033[0m %-16s udp  :%-7s CLOSED\n' "$n" "$lp"; fail=$((fail + 1))
      fi
    fi
  done
done < "$PORTS_CONF"

echo
echo "OK: $pass   CLOSED: $fail"
[ "$fail" -eq 0 ]
