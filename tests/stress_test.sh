#!/usr/bin/env bash
# Stress test: opens connections and HOLDS every one of them open at the
# same time (not stagger-and-close), ramping up in steps, until either a
# connection actually fails OR the box itself is running low on resources
# — reporting how many this port can actually sustain concurrently.
# Pure bash (/dev/tcp, /dev/udp) — no extra tools, nothing written to
# disk beyond /dev/shm bookkeeping for the run itself.
#
# WARNING: this exercises the real remote backend through the FULL forward
# chain, not just the local socket. It puts real load on the far end too.
#
# Safety: confirmed live that without a resource guard, this can ramp
# clean past "connections start failing" straight into the box running
# out of memory and dying (SSH included) — a stress test crashing the
# server it's testing defeats the entire point. So before every ramp
# step, available RAM and load average are checked, and the ramp stops
# BEFORE launching a step that could push things over the edge, not
# after the fact.
set -u

PORT="${1:-}"
PROTO="${2:-tcp}"
STEP="${3:-100}"
SETTLE="${4:-1}"
MAX="${5:-2000}"
HOLD="${6:-60}"
HOST="${7:-127.0.0.1}"

MIN_MEM_PCT="${RM_SOCAT_STRESS_MIN_MEM_PCT:-20}"

if [ -z "$PORT" ]; then
  echo "usage: stress_test.sh <local_port> [tcp|udp] [step] [settle_seconds] [max] [hold_seconds] [host]" >&2
  echo "example: stress_test.sh 1232 tcp 200 1 2000 90" >&2
  echo "raise the ceiling gradually, not in one huge jump — this puts real load on the box." >&2
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
echo "safety floor: stops ramping if available memory drops below ${MIN_MEM_PCT}% or load average gets extreme"
echo

WORKDIR="$(mktemp -d /dev/shm/rm-socat-stress.XXXXXX 2>/dev/null || mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# returns 1 (and prints why) the moment the box looks like it's in danger
# — checked BEFORE every ramp step, not after.
system_is_healthy() {
  local avail_pct load1 nproc_count danger
  avail_pct=$(awk '/MemAvailable:/{a=$2} /MemTotal:/{t=$2} END{if (t>0) printf "%d", (a*100)/t; else print 100}' /proc/meminfo 2>/dev/null)
  [ -z "$avail_pct" ] && avail_pct=100
  if [ "$avail_pct" -lt "$MIN_MEM_PCT" ]; then
    echo "!! available memory at ${avail_pct}% (floor: ${MIN_MEM_PCT}%) — stopping before this box runs out of RAM." >&2
    return 1
  fi
  load1="$(cut -d' ' -f1 /proc/loadavg 2>/dev/null)"
  nproc_count="$(nproc 2>/dev/null || echo 1)"
  if [ -n "$load1" ]; then
    danger="$(awk -v l="$load1" -v n="$nproc_count" 'BEGIN{print (l > n*8) ? 1 : 0}' 2>/dev/null)"
    if [ "$danger" = 1 ]; then
      echo "!! load average ${load1} is extreme for ${nproc_count} core(s) — stopping before things get worse." >&2
      return 1
    fi
  fi
  return 0
}

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
stopped_for_safety=0
while [ "$total" -lt "$MAX" ]; do
  if ! system_is_healthy; then
    stopped_for_safety=1
    break
  fi
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

if [ "$stopped_for_safety" = 1 ]; then
  echo
  echo "ceiling found (safety guard, not a real connection failure): ~$peak_ok concurrent connections were safely held."
  echo "this is a resource limit on THIS box, not the port — check RAM/CPU headroom before pushing further, ideally not over the same SSH session you're relying on."
fi

echo
echo "releasing everything..."
wait 2>/dev/null
echo "done."
