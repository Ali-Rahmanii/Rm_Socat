#!/usr/bin/env bash
# Stress test: opens connections and HOLDS every one of them open at the
# same time (not stagger-and-close), ramping up in steps, until new ones
# start failing — reporting how many this port can actually sustain
# concurrently. Pure bash (/dev/tcp, /dev/udp) — no extra tools, nothing
# written to disk beyond /dev/shm bookkeeping for the run itself.
#
# The previous version closed each connection after a few seconds — by
# the time step 3 was ramping up, step 1's connections had already
# closed, so "ok" only ever counted cumulative attempts, never how many
# were actually open at once. Fixed by holding every connection open for
# the whole test instead.
#
# WARNING: this exercises the real remote backend through the FULL forward
# chain, not just the local socket. It puts real load on the far end too.
set -u

PORT="${1:-}"
PROTO="${2:-tcp}"
STEP="${3:-100}"
SETTLE="${4:-1}"
MAX="${5:-5000}"
HOLD="${6:-60}"
HOST="${7:-127.0.0.1}"

if [ -z "$PORT" ]; then
  echo "usage: stress_test.sh <local_port> [tcp|udp] [step] [settle_seconds] [max] [hold_seconds] [host]" >&2
  echo "example: stress_test.sh 1232 tcp 200 1 20000 90" >&2
  exit 1
fi

# the shell running this test is subject to its OWN login session's
# ulimit -n/-u, not the raised LimitNOFILE the systemd units get — without
# this, the test itself (not the port) is usually what caps out first.
ulimit -n 1048576 2>/dev/null || ulimit -n "$(ulimit -Hn 2>/dev/null || echo 4096)" 2>/dev/null || true
ulimit -u unlimited 2>/dev/null || ulimit -u "$(ulimit -Hu 2>/dev/null || echo 4096)" 2>/dev/null || true

echo "this shell's ulimit -n / -u: $(ulimit -n) / $(ulimit -u)"
if [ "$(ulimit -n)" -lt 10000 ] 2>/dev/null; then
  echo "  (low — if the ceiling below looks small, log out and back in (or open a fresh SSH session) so /etc/security/limits.d/99-rm-socat.conf applies, then re-run)"
fi
echo "target: ${PROTO}://${HOST}:${PORT}   step: $STEP   settle: ${SETTLE}s   hold: ${HOLD}s   ceiling to probe: $MAX"
echo

WORKDIR="$(mktemp -d /dev/shm/rm-socat-stress.XXXXXX 2>/dev/null || mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

open_one() {
  local id="$1" fd
  if [ "$PROTO" = tcp ]; then
    if exec {fd}<>"/dev/tcp/${HOST}/${PORT}" 2>/dev/null; then
      : > "$WORKDIR/ok.$id"
      sleep "$HOLD" 2>/dev/null
    else
      : > "$WORKDIR/fail.$id"
    fi
  else
    if exec {fd}<>"/dev/udp/${HOST}/${PORT}" 2>/dev/null; then
      printf ping >&"$fd" 2>/dev/null
      : > "$WORKDIR/ok.$id"
      sleep "$HOLD" 2>/dev/null
    else
      : > "$WORKDIR/fail.$id"
    fi
  fi
}

total=0
peak_ok=0
while [ "$total" -lt "$MAX" ]; do
  for ((i = 0; i < STEP; i++)); do
    open_one "$((total + i))" &
  done
  total=$((total + STEP))
  sleep "$SETTLE"
  ok=$(find "$WORKDIR" -name 'ok.*' 2>/dev/null | wc -l)
  fail=$(find "$WORKDIR" -name 'fail.*' 2>/dev/null | wc -l)
  [ "$ok" -gt "$peak_ok" ] && peak_ok=$ok
  echo "attempted: $total   concurrently open: $ok   failed: $fail"
  if [ "$fail" -gt 0 ]; then
    echo
    echo "ceiling found: ~$peak_ok concurrent connections held open at once (failures started once attempts hit $total)."
    echo "if this is lower than expected: raise LimitNOFILE further, check nf_conntrack_max, and re-check the remote box's own limits too."
    break
  fi
done

echo
echo "holding at ~$peak_ok connections for ${HOLD}s total, then releasing everything..."
wait 2>/dev/null
echo "done."
