#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# control.sh - Service lifecycle manager for a deployed SPPMon release
#
# This script is shipped in every release under:
#   <sppmon>/current/bin/control.sh
#
# It controls the services of the CURRENT release via:
#   <sppmon>/current/meta/manifest.txt
#
# Runtime convention (under <sppmon>/volumes):
#   volumes/
#     data/   - persistent state
#     logs/   - service logs
#     run/    - pid files
#
# This script is intentionally lightweight (no systemd dependency).
# ------------------------------------------------------------------------------

# ---- Logging -----------------------------------------------------------------

ts() { date "+%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(ts)] $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# ---- Path resolution ----------------------------------------------------------
#
# control.sh lives at: <base>/current/bin/control.sh (via symlink), or directly at:
# <base>/releases/<release_id>/bin/control.sh
#
# We resolve:
#   RELEASE_DIR = .../releases/<release_id>
#   BASE_DIR    = .../sppmon
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"      # .../<release_id>
MANIFEST="$RELEASE_DIR/meta/manifest.txt"

# BASE_DIR = parent of releases/ directory
# Release dir is: <base>/releases/<release_id>
BASE_DIR="$(cd "$RELEASE_DIR/../.." && pwd)"

RELEASE_BIN="$RELEASE_DIR/bin"
RELEASE_CFG="$RELEASE_DIR/config"
VOLUMES="$BASE_DIR/volumes"
RUN_DIR="$VOLUMES/run"
LOG_DIR="$VOLUMES/logs"
DATA_DIR="$VOLUMES/data"

# ---- Defaults ----------------------------------------------------------------

DEFAULT_TAIL_LINES=200

# ---- Helpers -----------------------------------------------------------------

usage() {
  cat <<EOF
SPPMon control - manage services on a target host

USAGE:
  control.sh <command> [service] [options]

COMMANDS:
  status [service]              Show status of one service or all services
  start  <service>              Start a service
  stop   <service>              Stop a service
  restart <service>             Restart a service
  logs   <service> [--tail N]   Tail service logs (default: $DEFAULT_TAIL_LINES)
  list                          List services from the release manifest
  clean  logs|run               Clean logs or runtime pid files (SAFE)
  clean  data --force           DANGEROUS: remove persistent data for this deployment

NOTES:
  - This script operates on the CURRENT release (via the 'current' symlink).
  - PIDs are stored under: $RUN_DIR
  - Logs are stored under: $LOG_DIR

EOF
}

require_manifest() {
  [[ -f "$MANIFEST" ]] || die "Manifest not found: $MANIFEST (release may be corrupted)"
}

read_manifest_value() {
  local key="$1"
  require_manifest
  # manifest.txt is key=value lines
  grep -E "^${key}=" "$MANIFEST" | head -n 1 | cut -d'=' -f2- || true
}

list_services() {
  local services
  services="$(read_manifest_value "services")"
  [[ -n "$services" ]] || die "No 'services' found in manifest: $MANIFEST"
  # normalize comma-separated into newline
  echo "$services" | tr ',' '\n' | sed '/^\s*$/d'
}

pid_file() { echo "$RUN_DIR/$1.pid"; }
log_file() { echo "$LOG_DIR/$1.log"; }

is_running() {
  local svc="$1"
  local pidf; pidf="$(pid_file "$svc")"
  [[ -f "$pidf" ]] || return 1
  local pid; pid="$(cat "$pidf" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

ensure_runtime_dirs() {
  mkdir -p "$RUN_DIR" "$LOG_DIR" "$DATA_DIR"
}

# ---- Service command resolution ----------------------------------------------
#
# Keep the logic here minimal: map service -> binary + args.
# In the future, you can generate these args from inventory/services.yml and
# ship a resolved runtime config inside the release meta/ if needed.
#

service_binary() {
  local svc="$1"
  local bin="$RELEASE_BIN/$svc"
  [[ -x "$bin" ]] || die "Binary not found or not executable for '$svc': $bin"
  echo "$bin"
}

service_args() {
  local svc="$1"

  case "$svc" in
    alloy_agent)
      # Convention: templates are deployed into config/<service>/
      # Expect the service main config at config/alloy_agent/config.alloy
      local cfg="$RELEASE_CFG/alloy_agent/config.alloy"
      [[ -f "$cfg" ]] || die "Missing Alloy config: $cfg"
      echo "run \"$cfg\" --storage.path=\"$DATA_DIR/alloy\" --server.http.listen-addr=0.0.0.0:8121"
      ;;
    loki_exporter)
      # In many setups, loki_exporter is not a separate binary; it's a config extension.
      # If you later ship a separate binary, you can implement it here.
      # For now, fail explicitly (or treat as a no-op).
      die "Service 'loki_exporter' is configured as a template-only feature (no standalone runtime command)."
      ;;
    *)
      die "Unknown service '$svc' (no runtime command mapping)."
      ;;
  esac
}

# ---- Actions -----------------------------------------------------------------

cmd_list() {
  list_services
}

cmd_status_one() {
  local svc="$1"
  if is_running "$svc"; then
    local pid; pid="$(cat "$(pid_file "$svc")")"
    echo "$svc: running (pid=$pid)"
  else
    echo "$svc: stopped"
  fi
}

cmd_status() {
  if [[ $# -eq 0 ]]; then
    while read -r svc; do
      cmd_status_one "$svc"
    done < <(list_services)
    return 0
  fi
  cmd_status_one "$1"
}

cmd_start() {
  local svc="$1"
  [[ -n "$svc" ]] || die "start requires a service name"
  ensure_runtime_dirs

  if is_running "$svc"; then
    log "Service already running: $svc"
    return 0
  fi

  local bin; bin="$(service_binary "$svc")"
  local args; args="$(service_args "$svc")"

  local lf; lf="$(log_file "$svc")"
  local pidf; pidf="$(pid_file "$svc")"

  log "Starting: $svc"
  log "  bin:  $bin"
  log "  args: $args"
  log "  log:  $lf"

  # Start in background, capture pid
  # shellcheck disable=SC2086
  nohup bash -c "exec -a \"$svc\" \"$bin\" $args" >>"$lf" 2>&1 &
  local pid=$!
  echo "$pid" > "$pidf"

  sleep 0.2
  if is_running "$svc"; then
    log "OK: $svc started (pid=$pid)"
  else
    rm -f "$pidf" || true
    die "Failed to start $svc (see $lf)"
  fi
}

cmd_stop() {
  local svc="$1"
  [[ -n "$svc" ]] || die "stop requires a service name"
  ensure_runtime_dirs

  if ! is_running "$svc"; then
    log "Service already stopped: $svc"
    rm -f "$(pid_file "$svc")" || true
    return 0
  fi

  local pid; pid="$(cat "$(pid_file "$svc")")"
  log "Stopping: $svc (pid=$pid)"

  kill "$pid" 2>/dev/null || true

  # Wait up to ~5s
  for _ in {1..50}; do
    if kill -0 "$pid" 2>/dev/null; then
      sleep 0.1
    else
      break
    fi
  done

  if kill -0 "$pid" 2>/dev/null; then
    log "Process still alive, forcing: $svc (pid=$pid)"
    kill -9 "$pid" 2>/dev/null || true
  fi

  rm -f "$(pid_file "$svc")" || true
  log "OK: $svc stopped"
}

cmd_restart() {
  local svc="$1"
  [[ -n "$svc" ]] || die "restart requires a service name"
  cmd_stop "$svc"
  cmd_start "$svc"
}

cmd_logs() {
  local svc="$1"; shift || true
  [[ -n "$svc" ]] || die "logs requires a service name"
  ensure_runtime_dirs

  local tail_lines="$DEFAULT_TAIL_LINES"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tail) tail_lines="${2:-}"; shift 2 ;;
      *) die "Unknown option for logs: $1" ;;
    esac
  done

  local lf; lf="$(log_file "$svc")"
  [[ -f "$lf" ]] || die "Log file not found: $lf"
  tail -n "$tail_lines" -f "$lf"
}

cmd_clean() {
  local what="${1:-}"
  shift || true
  ensure_runtime_dirs

  case "$what" in
    logs)
      log "Cleaning logs: $LOG_DIR"
      rm -f "$LOG_DIR"/*.log 2>/dev/null || true
      log "OK: logs cleaned"
      ;;
    run)
      log "Cleaning runtime pid files: $RUN_DIR"
      rm -f "$RUN_DIR"/*.pid 2>/dev/null || true
      log "OK: run files cleaned"
      ;;
    data)
      local force="false"
      if [[ "${1:-}" == "--force" ]]; then
        force="true"
      fi
      [[ "$force" == "true" ]] || die "Refusing to remove data without --force"
      log "DANGEROUS: Removing data directory: $DATA_DIR"
      rm -rf "$DATA_DIR"
      mkdir -p "$DATA_DIR"
      log "OK: data cleaned"
      ;;
    *)
      die "clean expects: logs|run|data --force"
      ;;
  esac
}

# ---- Main --------------------------------------------------------------------

main() {
  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    --help|-h|help|"") usage; exit 0 ;;
    list)     cmd_list ;;
    status)   cmd_status "${1:-}" ;;
    start)    cmd_start "${1:-}" ;;
    stop)     cmd_stop "${1:-}" ;;
    restart)  cmd_restart "${1:-}" ;;
    logs)     cmd_logs "${@:-}" ;;
    clean)    cmd_clean "${@:-}" ;;
    *)
      die "Unknown command: $cmd (use --help)"
      ;;
  esac
}

main "$@"