#!/usr/bin/env bash
# Thin convenience wrapper — the real teardown lives in manage.sh's "purge"
# command (interactive menu option 9), which stops/disables every rm-socat
# systemd instance, removes the template unit and the sysctl/limits
# drop-ins, and can optionally delete this entire directory (including
# ports.conf and these scripts) so nothing is left behind.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/manage.sh" purge "$@"
