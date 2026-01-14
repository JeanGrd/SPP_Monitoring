#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# sppmon
# CLI entrypoint for SPP Monitoring deployments.
#
# Usage:
#   sppmon deploy   --app ICOM --env UAT --targets local --services alloy
#   sppmon rollback --app ICOM --env UAT --targets local --release <RELEASE_ID>
# ------------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

print_help() {
  cat <<'EOF'
SPP Monitoring CLI

USAGE:
  sppmon <command> [options]

COMMANDS:
  deploy      Build a release tarball and deploy it to targets (local or remote).
  rollback    Switch 'current' symlink to an older release on targets.

DEPLOY OPTIONS:
  --app <name>         Application name (e.g., ICOM, Jaguar)
  --env <name>         Environment name (e.g., UAT, PRD)
  --targets <list>     Comma-separated list of targets. Use "local" for local mode.
  --services <list>    Comma-separated list of services to include (e.g., alloy,loki_exporter)
  --remote             Enable SSH/SCP remote deployment (disabled by default for safety)
  --help               Show this help

ROLLBACK OPTIONS:
  --app <name>
  --env <name>
  --targets <list>
  --release <id>       Release ID to roll back to
  --remote             Enable SSH remote rollback (optional, if you implement remote rollback later)
  --help

ENV VARS:
  SPPMON_REMOTE_BASE   Remote base directory (default: /opt/sppmon)
  SPPMON_SSH_USER      SSH username (required for --remote)
  SPPMON_SSH_PORT      SSH port (default: 22)

EXAMPLES:
  ./scripts/sppmon deploy --app ICOM --env UAT --targets local --services alloy
  ./scripts/sppmon deploy --app ICOM --env UAT --targets srv1,srv2 --services alloy --remote

EOF
}

cmd="${1:-}"
shift || true

if [[ -z "$cmd" || "$cmd" == "--help" || "$cmd" == "-h" ]]; then
  print_help
  exit 0
fi

case "$cmd" in
  deploy)
    exec "$SCRIPT_DIR/actions/deploy.sh" --root "$ROOT_DIR" "$@"
    ;;
  rollback)
    exec "$SCRIPT_DIR/actions/rollback.sh" --root "$ROOT_DIR" "$@"
    ;;
  *)
    die "Unknown command: $cmd (use --help)"
    ;;
esac