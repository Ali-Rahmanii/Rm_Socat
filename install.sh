#!/usr/bin/env bash
# rm-socat installer. Run once, from wherever you cloned this repo:
#
#   git clone https://github.com/Ali-Rahmanii/Rm_Socat /opt/rm-socat
#   cd /opt/rm-socat && sudo ./install.sh
#
# Safe to re-run.
set -euo pipefail

log()  { printf '\033[1;32m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$1"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root: sudo ./install.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

log "checking dependencies..."
if ! command -v socat >/dev/null 2>&1; then
  log "installing socat..."
  if command -v apt-get >/dev/null 2>&1; then apt-get update -qq && apt-get install -y socat
  elif command -v dnf >/dev/null 2>&1; then dnf install -y socat
  elif command -v yum >/dev/null 2>&1; then yum install -y socat
  elif command -v apk >/dev/null 2>&1; then apk add --no-cache socat
  else die "no apt/dnf/yum/apk found — install socat manually and re-run"
  fi
fi
command -v ss >/dev/null 2>&1 || warn "iproute2 (ss) not found — status/test commands need it"

chmod +x manage.sh bin/rm-socat-run.sh tests/test_ports.sh tests/stress_test.sh

log "installing the systemd template unit..."
sed "s#__RUN_HELPER__#${SCRIPT_DIR}/bin/rm-socat-run.sh#" systemd/rm-socat@.service > /etc/systemd/system/rm-socat@.service
systemctl daemon-reload

if [ ! -f ports.conf ]; then
  cp ports.conf.example ports.conf
  log "created ports.conf from the example (real domains never get committed to git — see .gitignore)"
fi

log "tuning the kernel for high connection counts and dual-stack sockets..."
cat > /etc/sysctl.d/99-rm-socat.conf <<'EOF'
# written by rm-socat's install.sh
net.ipv6.bindv6only = 0
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.ip_local_port_range = 1024 65535
fs.file-max = 2097152
EOF
sysctl --system >/dev/null 2>&1 || warn "sysctl --system failed — apply /etc/sysctl.d/99-rm-socat.conf by hand"

cat > /etc/security/limits.d/99-rm-socat.conf <<'EOF'
# written by rm-socat's install.sh
* soft nofile 1048576
* hard nofile 1048576
* soft nproc  unlimited
* hard nproc  unlimited
EOF

echo
log "installed. next steps:"
echo "    nano ${SCRIPT_DIR}/ports.conf      # add your forwards — format is documented inside the file"
echo "    sudo ${SCRIPT_DIR}/manage.sh apply # bring systemd in sync with ports.conf"
echo "    sudo ${SCRIPT_DIR}/manage.sh       # interactive menu (status, add, remove, test, stress-test, purge)"
