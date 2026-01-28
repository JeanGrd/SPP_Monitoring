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

  Extra arguments after '--' are forwarded to the 'control' command's remote script.

COMMANDS:
  deploy      Build a release tarball and deploy it to targets.
  rollback    Switch 'current' symlink to an older release on targets.
  control     Run current/bin/control.sh on targets via SSH.

GLOBAL OPTIONS:
  --use-marley         Resolve targets using Marley (can be placed anywhere).
  --help, -h           Show this help.

FILTERS (used with --use-marley or direct targeting):
  --app <name>         Application name (e.g., ICOM, Jaguar)
  --env <name>         Environment name (e.g., UAT, PRD)
  --targets <list>     Comma-separated targets or a Marley FQDN filter.
                       Required without --use-marley, optional with it.
  --os <name>          OS filter for Marley (optional)

DEPLOY OPTIONS:
  --services <list>    Comma-separated services (e.g., alloy,loki_exporter)
  (other deploy flags are forwarded to actions/deploy.sh)

ROLLBACK OPTIONS:
  --release <id>       Release ID to roll back to
  --previous           Switch to previous release (if supported by rollback.sh)
  --latest             Switch to latest release (if supported by rollback.sh)
  (other rollback flags are forwarded to actions/rollback.sh)

CONTROL:
  Arguments after are forwarded to <remote_base>/current/bin/control.sh.
  status [service]              Show status of one service or all services
  start  <service|all>          Start one service or all services
  stop   <service|all>          Stop one service or all services
  restart <service|all>         Restart one service or all services
  logs   <service> [--tail N]   Tail service logs (default: $DEFAULT_TAIL_LINES)
  list                          List services from the environment
  clean  logs|run               Clean logs or runtime pid files (SAFE)
  clean  data --force           DANGEROUS: remove persistent data for this deployment

ENV VARS:
  SPPMON_REMOTE_BASE   Remote base directory on the target (default: SPP_Monitoring; relative to SSH login dir)

EXAMPLES:
  ./scripts/sppmon deploy   --app ICOM --env UAT --targets 10.1.2.3 --services alloy
  ./scripts/sppmon control  --app ICOM --env UAT --targets 10.1.2.3 -- status
  ./scripts/sppmon --use-marley deploy  --app ICOM --env UAT --services alloy
  ./scripts/sppmon --use-marley control --app ICOM --env UAT -- status
EOF
}

# -----------------------------------------------------------------------------
# Parse global flags anywhere (only --use-marley + help)
# -----------------------------------------------------------------------------
use_marley=0
argv=()
for a in "$@"; do
  case "$a" in
    --use-marley) use_marley=1 ;;
    --help|-h) print_help; exit 0 ;;
    *) argv+=("$a") ;;
  esac
done

[[ ${#argv[@]} -ge 1 ]] || { print_help; exit 1; }

cmd="${argv[0]}"
shift_args=("${argv[@]:1}")

case "$cmd" in
  deploy|rollback|control) ;;
  *) die "Unknown command: $cmd (use --help)" ;;
esac

# Helper: remove our routing flags so we can forward the rest as-is.
# Keeps the code readable and avoids duplication.
forward_args=()
while [[ ${#shift_args[@]} -gt 0 ]]; do
  case "${shift_args[0]}" in
    --app|--env|--targets|--os)
      # drop key + value
      shift_args=("${shift_args[@]:2}")
      ;;
    --use-marley)
      # already consumed globally
      shift_args=("${shift_args[@]:1}")
      ;;
    *)
      forward_args+=("${shift_args[0]}")
      shift_args=("${shift_args[@]:1}")
      ;;
  esac
done

# Rebuild shift_args for get_arg_value() (it expects the original CLI tail)
# (Yes: this is intentional; we keep get_arg_value simple.)
shift_args=("${argv[@]:1}")

if [[ $use_marley -eq 0 ]]; then
  # Non-Marley mode: app/env/targets are required.
  app="$(get_arg_value --app)"
  env="$(get_arg_value --env)"
  targets="$(get_arg_value --targets)"

  [[ -n "$app" ]] || die "--app is required"
  [[ -n "$env" ]] || die "--env is required"
  [[ -n "$targets" ]] || die "--targets is required unless --use-marley is specified"

  #tenant="$(get_tenant "$app" "$env")"
  tenant="jean"

  case "$cmd" in
    deploy)
      exec "$SCRIPT_DIR/actions/deploy.sh" \
        --root "$ROOT_DIR" \
        --tenant "$tenant" \
        --app "$app" \
        --env "$env" \
        --targets "$targets" \
        "${forward_args[@]}"
      ;;
    rollback)
      exec "$SCRIPT_DIR/actions/rollback.sh" \
        --root "$ROOT_DIR" \
        --tenant "$tenant" \
        --targets "$targets" \
        "${forward_args[@]}"
      ;;
    control)
      IFS=',' read -r -a tlist <<< "$targets"
      for t in "${tlist[@]}"; do
        [[ -n "$t" ]] || continue
        remote_control "$tenant" "$t" "${forward_args[@]}"
      done
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
        [[ -n "${fqdn:-}" ]] || continue
        log "Target from marley: $fqdn ($row_app / $row_env / $row_os)"

        #tenant="$(get_tenant "$row_app" "$row_env")"
        tenant="jean"

        case "$cmd" in
          deploy)
            "$SCRIPT_DIR/actions/deploy.sh" \
              --root "$ROOT_DIR" \
              --tenant "$tenant" \
              --app "$row_app" \
              --env "$row_env" \
              --targets "$fqdn" \
              "${forward_args[@]}"
            ;;
          rollback)
            "$SCRIPT_DIR/actions/rollback.sh" \
              --root "$ROOT_DIR" \
              --tenant "$tenant" \
              --targets "$fqdn" \
              "${forward_args[@]}"
            ;;
          control)
            remote_control "$tenant" "$fqdn" "${forward_args[@]}"
            ;;
        esac
      done

  exit 0
fi