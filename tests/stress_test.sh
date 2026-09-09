#!/usr/bin/env bash
# Stress test: ramps concurrent connections against ONE forwarded port,
# step by step, until failures start — reporting the real ceiling this box
# (and the chain behind it) can currently sustain. Pure bash (/dev/tcp,
# /dev/udp) — no extra tools installed, nothing written to disk (uses
# /dev/shm) beyond the run itself.
#
# WARNING: this exercises the real remote backend through the FULL forward
# chain, not just the local socket. It puts real load on the far end too.
set -u

PORT="${1:-}"
PROTO="${2:-tcp}"
STEP="${3:-100}"
HOLD="${4:-3}"
MAX="${5:-5000}"
HOST="${6:-127.0.0.1}"

if [ -z "$PORT" ]; then
  echo "usage: stress_test.sh <local_port> [tcp|udp] [step] [hold_seconds] [max] [host]" >&2
  echo "example: stress_test.sh 1232 tcp 200 3 20000" >&2
  exit 1
fi

echo "ulimit -n for this shell: $(ulimit -n)"
echo "target: ${PROTO}://${HOST}:${PORT}   step: $STEP   hold/step: ${HOLD}s   ceiling to probe: $MAX"
echo

WORKDIR="$(mktemp -d /dev/shm/rm-socat-stress.XXXXXX 2>/dev/null || mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

open_one() {
  local id="$1" fd
  if [ "$PROTO" = tcp ]; then
    if exec {fd}<>"/dev/tcp/${HOST}/${PORT}" 2>/dev/null; then
      : > "$WORKDIR/ok.$id"
      sleep "$HOLD"
      eval "exec ${fd}>&-" 2>/dev/null
    else
      : > "$WORKDIR/fail.$id"
    fi
  else
    if exec {fd}<>"/dev/udp/${HOST}/${PORT}" 2>/dev/null; then
      printf ping >&"$fd" 2>/dev/null
      : > "$WORKDIR/ok.$id"
      sleep "$HOLD"
      eval "exec ${fd}>&-" 2>/dev/null
    else
      : > "$WORKDIR/fail.$id"
    fi
  fi
}

total=0
while [ "$total" -lt "$MAX" ]; do
  for ((i = 0; i < STEP; i++)); do
    open_one "$((total + i))" &
  done
  total=$((total + STEP))
  sleep "$HOLD"
  ok=$(find "$WORKDIR" -name 'ok.*' 2>/dev/null | wc -l)
  fail=$(find "$WORKDIR" -name 'fail.*' 2>/dev/null | wc -l)
  echo "attempted: $total   ok: $ok   failed: $fail"
  if [ "$fail" -gt 0 ]; then
    echo
    echo "ceiling found: ~$ok concurrent connections held (first failures appeared once attempts hit $total)."
    echo "if this is lower than expected: raise LimitNOFILE further, check nf_conntrack_max, and re-check the remote box's own limits too."
    break
  fi
done
wait 2>/dev/null
echo "done."
