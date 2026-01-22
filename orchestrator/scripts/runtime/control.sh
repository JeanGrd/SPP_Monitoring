#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# control.sh - Service lifecycle manager for a deployed SPPMon release
#
# This script manages the CURRENT release under <sppmon>/current (symlink to a release).
#
# Services and runtime args are provided by: <release>/bin/environment.sh
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

# environment.sh lives next to this script and is the single source of truth for
# release/base paths. control.sh only resolves ENV_FILE and sources it.

RELEASE_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$RELEASE_BIN/environment.sh"

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
  start  <service|all>          Start one service or all services
  stop   <service|all>          Stop one service or all services
  restart <service|all>         Restart one service or all services
  logs   <service> [--tail N]   Tail service logs (default: $DEFAULT_TAIL_LINES)
  list                          List services from the environment
  clean  logs|run               Clean logs or runtime pid files (SAFE)
  clean  data --force           DANGEROUS: remove persistent data for this deployment

NOTES:
  - Runtime services are resolved from: $ENV_FILE (SPPMON_RUNTIME_SERVICES)
  - Binaries are under: $SPPMON_LIB_DIR
  - Entrypoint and flags are defined by SPPMON_ARGS__* in environment.sh
  - PIDs are stored under: $SPPMON_RUN_DIR
  - Logs are stored under: $SPPMON_LOG_DIR

EOF
}

pid_file() { echo "$SPPMON_RUN_DIR/$1.pid"; }
log_file() { echo "$SPPMON_LOG_DIR/$1.log"; }

is_running() {
  local svc="$1"
  local pidf; pidf="$(pid_file "$svc")"
  [[ -f "$pidf" ]] || return 1
  local pid; pid="$(cat "$pidf" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

ensure_runtime_dirs() {
  require_environment
  mkdir -p "$SPPMON_RUN_DIR" "$SPPMON_LOG_DIR" "$SPPMON_DATA_DIR"
}

# Clear previously loaded SPPMon runtime variables so environment.sh changes are reflected.
clear_environment_vars() {
  # Only clear variables that are owned by SPPMon to allow live edits.
  # Do NOT unset everything in the shell.
  local v
  for v in $(compgen -v | grep -E '^(SPPMON_|APP$|ENV$|ENDPOINT_)' || true); do
    unset "$v" 2>/dev/null || true
  done
}

require_environment() {
  [[ -f "$ENV_FILE" ]] || die "environment.sh not found: $ENV_FILE (release may be corrupted)"

  # Reload fresh every time to support live edits.
  clear_environment_vars

  # shellcheck disable=SC1090
  source "$ENV_FILE"

  [[ -n "${SPPMON_RUNTIME_SERVICES:-}" ]] || die "Invalid environment.sh: SPPMON_RUNTIME_SERVICES is not set"

  # Keep compatibility with service args that may reference either the short
  # names (SPPMON_ETC_DIR, SPPMON_DATA_DIR, ...) or the prefixed ones (SPPMON_DATA_DIR, ...).
  : "${SPPMON_ETC_DIR:="$SPPMON_ETC_DIR"}"
  : "${SPPMON_LIB_DIR:="$SPPMON_LIB_DIR"}"
  : "${SPPMON_DATA_DIR:="$SPPMON_DATA_DIR"}"
  : "${SPPMON_LOG_DIR:="$SPPMON_LOG_DIR"}"
  : "${SPPMON_RUN_DIR:="$SPPMON_RUN_DIR"}"

  export SPPMON_ETC_DIR SPPMON_LIB_DIR SPPMON_DATA_DIR SPPMON_LOG_DIR SPPMON_RUN_DIR
}

safe_key() {
  echo "$1" | sed -E 's/[^A-Za-z0-9_]/_/g'
}

list_services() {
  require_environment
  local s
  for s in $SPPMON_RUNTIME_SERVICES; do
    [[ -n "$s" ]] && echo "$s"
  done
}

reverse_lines() {
  # Portable reverse for a newline-delimited list.
  awk '{a[NR]=$0} END{for(i=NR;i>=1;i--) print a[i]}'
}

service_args() {
  local svc="$1"
  require_environment

  local safe var val
  safe="$(safe_key "$svc")"
  var="SPPMON_ARGS__${safe}"
  val="${!var-}"

  [[ -n "${val//[[:space:]]/}" ]] || die "Service '$svc' has no args defined (not launchable)"

  # If args look like 'run <dir>' and the dir contains config.alloy, fix it to 'run <dir>/config.alloy'.
  local a1 a2 rest
  a1="$(echo "$val" | awk '{print $1}')"
  a2="$(echo "$val" | awk '{print $2}')"
  rest="$(echo "$val" | cut -d' ' -s -f3-)"

  if [[ "$a1" == "run" && -n "$a2" ]]; then
    local abs
    if [[ "$a2" = /* ]]; then
      abs="$a2"
    else
      abs="$SPPMON_RELEASE_DIR/$a2"
    fi
    if [[ -d "$abs" && -f "$abs/config.alloy" ]]; then
      if [[ -n "$rest" ]]; then
        val="run $a2/config.alloy $rest"
      else
        val="run $a2/config.alloy"
      fi
    fi
  fi

  echo "$val"
}

service_binary() {
  local svc="$1"
  require_environment

  local safe var bin
  safe="$(safe_key "$svc")"
  var="SPPMON_BIN__${safe}"
  bin="${!var-}"

  [[ -n "${bin//[[:space:]]/}" ]] || die "Service '$svc' has no binary defined"

  local path="$SPPMON_LIB_DIR/$bin"
  [[ -x "$path" ]] || die "Binary not found or not executable: $path"
  echo "$path"
}

# ---- Actions -----------------------------------------------------------------

cmd_list() {
  list_services
}

cmd_status_one() {
  local svc="$1"
  if is_running "$svc"; then
    local pid; pid="$(cat "$(pid_file "$svc")" 2>/dev/null || true)"
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
  local svc="${1:-}"
  [[ -n "$svc" ]] || die "start requires a service name (or 'all')"
  ensure_runtime_dirs

  if [[ "$svc" == "all" ]]; then
    local s
    while read -r s; do
      [[ -n "$s" ]] || continue
      cmd_start "$s"
    done < <(list_services)
    return 0
  fi

  if ! list_services | grep -qx "$svc"; then
    log "Unknown service: $svc"
    log "Available services:"
    list_services | sed 's/^/  - /' >&2
    die "Unknown service '$svc'"
  fi

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

  local bin_base
  bin_base="$(basename "$bin")"

  # Set argv[0] to help identify processes quickly (ps/top).
  # Example: sppmon:alloy_agent:alloy
  local proc_name
  proc_name="sppmon:${svc}:${bin_base}"

  # Start in background, capture pid
  # shellcheck disable=SC2086
  nohup bash -c "cd \"$SPPMON_RELEASE_DIR\" && exec -a \"$proc_name\" \"$bin\" $args" >>"$lf" 2>&1 &
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
  local svc="${1:-}"
  [[ -n "$svc" ]] || die "stop requires a service name (or 'all')"
  ensure_runtime_dirs

  if [[ "$svc" == "all" ]]; then
    local s
    # Stop in reverse order to reduce the chance of stopping a dependency last.
    while read -r s; do
      [[ -n "$s" ]] || continue
      cmd_stop "$s"
    done < <(list_services | reverse_lines)
    return 0
  fi

  if ! list_services | grep -qx "$svc"; then
    log "Unknown service: $svc"
    log "Available services:"
    list_services | sed 's/^/  - /' >&2
    die "Unknown service '$svc'"
  fi

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
  local svc="${1:-}"
  [[ -n "$svc" ]] || die "restart requires a service name (or 'all')"

  if [[ "$svc" == "all" ]]; then
    cmd_stop all
    cmd_start all
    return 0
  fi

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
      log "Cleaning logs: $SPPMON_LOG_DIR"
      rm -f "$SPPMON_LOG_DIR"/*.log 2>/dev/null || true
      log "OK: logs cleaned"
      ;;
    run)
      log "Cleaning runtime pid files: $SPPMON_RUN_DIR"
      rm -f "$SPPMON_RUN_DIR"/*.pid 2>/dev/null || true
      log "OK: run files cleaned"
      ;;
    data)
      local force="false"
      if [[ "${1:-}" == "--force" ]]; then
        force="true"
      fi
      [[ "$force" == "true" ]] || die "Refusing to remove data without --force"
      log "DANGEROUS: Removing data directory: $SPPMON_DATA_DIR"
      rm -rf "$SPPMON_DATA_DIR"
      mkdir -p "$SPPMON_DATA_DIR"
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

  require_environment

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