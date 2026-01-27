#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/utils.sh
source "$SCRIPT_DIR/lib/utils.sh"

print_help() {
  cat <<'EOF'
SPP Monitoring CLI

USAGE:
  sppmon <command> [options]

COMMANDS:
  deploy      Build a release tarball and deploy it to targets (local or remote).
  rollback    Switch 'current' symlink to an older release on targets.

GLOBAL OPTIONS:
  --use-marley

DEPLOY OPTIONS:
  --app <name>         Application name (e.g., ICOM, Jaguar)
  --env <name>         Environment name (e.g., UAT, PRD)
  --targets <list>     Comma-separated list of targets. Use "local" for local mode. Optional with --use-marley.
  --services <list>    Comma-separated list of services to include (e.g., alloy,loki_exporter)
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
  ./scripts/sppmon deploy --app ICOM --env UAT --targets srv1,srv2 --services alloy

EOF
}

use_marley=0

# Check for --use-marley anywhere in args and remove it
args=()
for arg in "$@"; do
  if [[ "$arg" == "--use-marley" ]]; then
    use_marley=1
  else
    args+=("$arg")
  fi
done

cmd="${args[0]}"
shift_args=("${args[@]:1}")

if [[ "$cmd" == "--help" || "$cmd" == "-h" ]]; then
  print_help
  exit 0
fi

if [[ "$cmd" != "deploy" && "$cmd" != "rollback" && "$cmd" != "control" ]]; then
  die "Unknown command: $cmd (use --help)"
fi

if [[ $use_marley -eq 0 ]]; then

  case "$cmd" in
    deploy)
      exec "$SCRIPT_DIR/actions/deploy.sh" --root "$ROOT_DIR" "${shift_args[@]}"
      ;;
    rollback)
      exec "$SCRIPT_DIR/actions/rollback.sh" --root "$ROOT_DIR" "${shift_args[@]}"
      ;;
    control)
      exec "$SCRIPT_DIR/actions/control.sh" --root "$ROOT_DIR" "${shift_args[@]}"
      ;;
  esac

else
  log "Using marley inventory"

  app="$(get_arg_value --app)"
  env="$(get_arg_value --env)"
  targets="$(get_arg_value --targets)"
  os="$(get_arg_value --os)"

  marley_query "$app" "$env" "$targets" "$os" \
  | tail -n +2 \
  | while IFS=',' read -r row_app row_env fqdn row_os; do
      [[ -z "$fqdn" ]] && continue
      log "Target from marley: $fqdn ($row_app / $row_env / $row_os)"

      case "$cmd" in
        deploy)
          "$SCRIPT_DIR/actions/deploy.sh" \
            --root "$ROOT_DIR" \
            --app "$row_app" \
            --env "$row_env" \
            --targets "$fqdn" \
            --tenant "jean" \
            "${shift_args[@]}"
          ;;
        rollback)
          "$SCRIPT_DIR/actions/rollback.sh" \
            --root "$ROOT_DIR" \
            --tenant "$TENANT_ID" \
            --targets "$fqdn" \
            "${shift_args[@]}"
          ;;
        control)
          "$SCRIPT_DIR/actions/control.sh" \
            --root "$ROOT_DIR" \
            --tenant "$TENANT_ID" \
            --targets "$fqdn" \
            "${shift_args[@]}"
          ;;
      esac
  done

  exit 0
fi