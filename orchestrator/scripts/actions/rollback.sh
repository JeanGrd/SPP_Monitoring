#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# rollback.sh
#
# Responsibilities:
# - Switch the `current` symlink to a specified release
# - Refresh the Prometheus inventory file (version_present.prom)
#
# Simulation (no SSH):
#   If --remote is NOT provided, targets are treated as simulated hosts under:
#     <repo>/host/<target><REMOTE_BASE>/
#
# Remote mode (SSH):
#   Not enabled here yet (placeholder), but the CLI flag exists.
# ------------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# shellcheck source=../lib/common.sh
source "$LIB_DIR/common.sh"

DEFAULT_REMOTE_BASE="/sppmon"

ROOT=""
APP=""
ENV_NAME=""
TARGETS_RAW=""
RELEASE_ID=""
LIST_ONLY="false"
USE_PREVIOUS="false"
USE_LATEST="false"
ENABLE_REMOTE="false"

print_help() {
  cat <<'EOF'
rollback.sh - Switch the active release (rollback)

USAGE:
  rollback.sh --root <path> --app <APP> --env <ENV> --targets <list> (--release <RELEASE_ID> | --previous | --latest | --list) [--remote]

REQUIRED:
  --root <path>        Repository root (passed by sppmon)
  --app <name>         Application name (ICOM, Jaguar, ...)
  --env <name>         Environment (UAT, PRD, ...)
  --targets <list>     Comma-separated targets (e.g. "188.23.34.10,188.23.34.11")

OPTIONAL:
  --release <id>       Release ID to activate (must exist under releases/)
  --list               List available releases and show which one is active
  --previous           Activate the most recent release that is NOT current
  --latest             Activate the most recent release (equivalent to "switch back to latest")
  --remote             Enable SSH rollback (placeholder for later)
  --help               Show this help

NOTES:
  - If --remote is NOT provided, rollback runs in simulation mode under <repo>/host/<target>/...
  - After switching `current`, this updates releases/version_present.prom for dashboards.
  - --previous requires at least two releases on disk.
  - --latest requires at least one release on disk.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --root)     ROOT="${2:-}"; shift 2 ;;
      --app)      APP="${2:-}"; shift 2 ;;
      --env)      ENV_NAME="${2:-}"; shift 2 ;;
      --targets)  TARGETS_RAW="${2:-}"; shift 2 ;;
      --release)  RELEASE_ID="${2:-}"; shift 2 ;;
      --list)     LIST_ONLY="true"; shift ;;
      --previous) USE_PREVIOUS="true"; shift ;;
      --latest)   USE_LATEST="true"; shift ;;
      --remote)   ENABLE_REMOTE="true"; shift ;;
      --help|-h)  print_help; exit 0 ;;
      *) die "Unknown argument: $1 (use --help)" ;;
    esac
  done
}

validate_args() {
  [[ -n "$ROOT" ]]        || die "--root is required"
  [[ -n "$APP" ]]         || die "--app is required"
  [[ -n "$ENV_NAME" ]]    || die "--env is required"
  [[ -n "$TARGETS_RAW" ]] || die "--targets is required"

  is_valid_name "$APP"      || die "Invalid app name: $APP"
  is_valid_name "$ENV_NAME" || die "Invalid env name: $ENV_NAME"

  if [[ "$LIST_ONLY" != "true" && "$USE_PREVIOUS" != "true" && "$USE_LATEST" != "true" ]]; then
    [[ -n "$RELEASE_ID" ]] || die "--release is required (or use --previous / --latest / --list)"
  fi

  if [[ "$LIST_ONLY" == "true" && ( -n "$RELEASE_ID" || "$USE_PREVIOUS" == "true" || "$USE_LATEST" == "true" ) ]]; then
    die "--list cannot be combined with --release, --previous, or --latest"
  fi
  if [[ "$USE_PREVIOUS" == "true" && ( -n "$RELEASE_ID" || "$USE_LATEST" == "true" ) ]]; then
    die "--previous cannot be combined with --release or --latest"
  fi
  if [[ "$USE_LATEST" == "true" && -n "$RELEASE_ID" ]]; then
    die "--latest cannot be combined with --release"
  fi

  require_cmd mkdir
  require_cmd rm
  require_cmd ln
  require_cmd readlink
}

write_inventory_prom() {
  local releases_dir="$1"
  local current_link="$2"

  local inventory_file="$releases_dir/version_present.prom"
  local current_basename

  current_basename="$(basename "$(readlink "$current_link")")"

  {
    echo "# HELP sppmon_release Release inventory (1 = present on disk). Label current=\"true\" marks the active release."
    echo "# TYPE sppmon_release gauge"

    for d in "$releases_dir"/*; do
      [[ -d "$d" ]] || continue
      [[ "$(basename "$d")" == .* ]] && continue

      if [[ "$(basename "$d")" == "$current_basename" ]]; then
        echo "sppmon_release{release=\"$(basename "$d")\",current=\"true\"} 1"
      else
        echo "sppmon_release{release=\"$(basename "$d")\",current=\"false\"} 1"
      fi
    done
  } > "$inventory_file"

  log "Wrote release inventory: $inventory_file"
}

get_current_release() {
  local current_link="$1"
  if [[ -L "$current_link" ]]; then
    basename "$(readlink "$current_link")"
  else
    echo ""
  fi
}

list_releases() {
  local releases_dir="$1"
  local current_release="$2"

  if [[ ! -d "$releases_dir" ]]; then
    echo "(no releases directory)"
    return
  fi

  # Newest first (release IDs include sortable timestamps)
  local rel
  local found="false"
  while IFS= read -r rel; do
    found="true"
    if [[ "$rel" == "$current_release" ]]; then
      echo "* $rel (current)"
    else
      echo "  $rel"
    fi
  done < <(find "$releases_dir" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -exec basename {} \; | sort -r)

  if [[ "$found" == "false" ]]; then
    echo "(no releases found)"
  fi
}

select_previous_release() {
  local releases_dir="$1"
  local current_release="$2"

  # Newest first
  local rel
  while IFS= read -r rel; do
    [[ "$rel" == "$current_release" ]] && continue
    echo "$rel"
    return 0
  done < <(find "$releases_dir" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -exec basename {} \; | sort -r)

  echo ""
}

select_latest_release() {
  local releases_dir="$1"

  # Newest first
  find "$releases_dir" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -exec basename {} \; | sort -r | head -n 1
}

rollback_simulated_host() {
  local target_name="$1"

  local simulated_host_root="$ROOT/host/$target_name"
  local remote_base="${SPPMON_REMOTE_BASE:-$DEFAULT_REMOTE_BASE}"

  # Layout: <repo>/host/<target><REMOTE_BASE>/{releases,current}
  local base="$simulated_host_root$remote_base"
  [[ "$base" == "$simulated_host_root"* ]] || die "Refusing to operate outside simulated host root: base=$base"

  local releases_dir="$base/releases"
  local current_link="$base/current"

  local current_release
  current_release="$(get_current_release "$current_link")"

  if [[ "$LIST_ONLY" == "true" ]]; then
    echo ""
    echo "Target: $target_name"
    echo "Base:   $base"
    echo "Releases:"
    list_releases "$releases_dir" "$current_release"
    return 0
  fi

  local selected_release="$RELEASE_ID"
  if [[ "$USE_PREVIOUS" == "true" ]]; then
    selected_release="$(select_previous_release "$releases_dir" "$current_release")"
    [[ -n "$selected_release" ]] || die "--previous requested but no previous release is available (need at least 2 releases)"
    log "Selected previous release: $selected_release (current was: ${current_release:-none})"
  fi
  if [[ "$USE_LATEST" == "true" ]]; then
    selected_release="$(select_latest_release "$releases_dir")"
    [[ -n "$selected_release" ]] || die "--latest requested but no release is available (need at least 1 release)"
    log "Selected latest release: $selected_release (current was: ${current_release:-none})"
  fi

  local target_release_dir="$releases_dir/$selected_release"

  log "Rollback (simulation) on target: $target_name"
  log "Using base: $base"

  [[ -d "$releases_dir" ]] || die "No releases directory found: $releases_dir"
  [[ -d "$target_release_dir" ]] || die "Release not found: $target_release_dir"

  # Switch current symlink atomically
  ln -sfn "$target_release_dir" "$current_link"
  log "OK: current -> $(readlink "$current_link")"

  # Refresh inventory file
  write_inventory_prom "$releases_dir" "$current_link"
}

rollback_remote_placeholder() {
  warn "Remote rollback requested but SSH logic is not enabled yet (placeholder)."
  warn "Use simulation mode (no --remote) for now."
}

main() {
  parse_args "$@"
  validate_args

  local host
  for host in $(normalize_list "$TARGETS_RAW"); do
    if [[ "$ENABLE_REMOTE" == "true" ]]; then
      rollback_remote_placeholder
    else
      rollback_simulated_host "$host"
    fi
  done

  if [[ "$LIST_ONLY" != "true" ]]; then
    log "Rollback completed."
  fi
}

main "$@"