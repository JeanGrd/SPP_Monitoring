#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# rollback.sh
#
# Responsibilities:
# - Switch the `current` symlink to a specified release on remote targets
# - Refresh the Prometheus catalogue index file (releases/version_present.prom)
#
# Remote layout (relative to the remote login directory by default):
#   SPP_Monitoring/
#     current -> releases/<release_id>
#     releases/<release_id>/...
#     volumes/...
# ------------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# shellcheck source=../lib/utils.sh
source "$LIB_DIR/utils.sh"

DEFAULT_REMOTE_BASE="SPP_Monitoring"

ROOT=""
APP=""
ENV_NAME=""
TARGETS_RAW=""
RELEASE_ID=""
LIST_ONLY="false"
USE_PREVIOUS="false"
USE_LATEST="false"

print_help() {
  cat <<'EOF'
rollback.sh - Switch the active release on remote targets

USAGE:
  rollback.sh --root <path> --app <APP> --env <ENV> --targets <list> (--release <RELEASE_ID> | --previous | --latest | --list)

REQUIRED:
  --targets <list>     Comma-separated targets (e.g. "188.23.34.10,188.23.34.11")

ACTIONS:
  --release <id>       Activate the given release ID
  --previous           Activate the most recent release that is OLDER than the current one
  --latest             Activate the most recent release (switch back to latest)
  --list               List available releases and show which one is active

OTHER:
  --help               Show this help

NOTES:
  - Rollback is performed over SSH using the tenant/user resolved from catalogue/apps.yml (apps.<APP>.tenants.<ENV>).
  - The current symlink is always set as: current -> releases/<release_id> (relative link).
  - After switching `current`, this updates releases/version_present.prom.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --targets)  TARGETS_RAW="${2:-}"; shift 2 ;;
      --release)  RELEASE_ID="${2:-}"; shift 2 ;;
      --list)     LIST_ONLY="true"; shift ;;
      --previous) USE_PREVIOUS="true"; shift ;;
      --latest)   USE_LATEST="true"; shift ;;
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

  require_cmd ssh
  require_cmd ln

  # yq is required to read catalogue YAML
  [[ -x "$ROOT/tools/yq" ]] || die "yq is required at: $ROOT/tools/yq"
}

strip_leading_slash() {
  local p="$1"
  p="${p#/}"
  echo "$p"
}

resolve_tenant() {
  local apps_file="$ROOT/catalogue/apps.yml"
  [[ -f "$apps_file" ]] || die "Missing apps catalogue: $apps_file"

  local q=".apps.${APP}.tenants.${ENV_NAME}"
  local tenant
  tenant="$($ROOT/tools/yq -r "$q" "$apps_file" 2>/dev/null || true)"

  [[ -n "${tenant//[[:space:]]/}" && "$tenant" != "null" ]] || die "Unable to resolve tenant for $APP/$ENV_NAME (expected: apps.<APP>.tenants.<ENV> in $apps_file)"
  echo "$tenant"
}

rollback_remote_host() {
  local target_host="$1"
  local tenant_user="$2"

  local remote_base_rel
  remote_base_rel="$(strip_leading_slash "${SPPMON_REMOTE_BASE:-$DEFAULT_REMOTE_BASE}")"

  local ssh_dest="$tenant_user@$target_host"

  log "Rollback target: $target_host"
  log "Using remote base: $remote_base_rel (relative to login dir)"

  # Pass action flags to remote shell. Selection is done remotely based on what exists on disk.
  local action_release="$RELEASE_ID"
  local action_list="$LIST_ONLY"
  local action_prev="$USE_PREVIOUS"
  local action_latest="$USE_LATEST"

  # IMPORTANT: when RELEASE_ID is empty (e.g., --previous/--latest), some SSH/bash combos can drop
  # the empty positional argument and shift parameters on the remote. Use a sentinel to keep arity.
  local action_release_arg
  action_release_arg="$action_release"
  if [[ -z "$action_release_arg" ]]; then
    action_release_arg="__SPPMON_NONE__"
  fi

  # You may centralize SSH options in utils.sh; keep minimal safe defaults here.
  local SSH_OPTS="${SPPMON_SSH_OPTS:--o StrictHostKeyChecking=no}"

  ssh $SSH_OPTS "$ssh_dest" bash -s -- \
    "$remote_base_rel" \
    "$action_release_arg" \
    "$action_list" \
    "$action_prev" \
    "$action_latest" \
    <<'REMOTE_SH'
set -euo pipefail

log() {
  # Bash 3/4 compatible timestamp (no printf %(...)T)
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
  log "ERROR: $*"
  exit 1
}

remote_base="${1:-}"
release_id_req="${2:-}"
if [[ "$release_id_req" == "__SPPMON_NONE__" ]]; then
  release_id_req=""
fi
list_only="${3:-false}"
use_previous="${4:-false}"
use_latest="${5:-false}"

[[ -n "$remote_base" ]] || die "Missing remote_base argument"

base_dir="$remote_base"
releases_dir="$base_dir/releases"
current_link="$base_dir/current"

[[ -d "$releases_dir" ]] || die "No releases directory found: $releases_dir"

get_current_release() {
  if [[ -L "$current_link" ]]; then
    basename "$(readlink "$current_link")"
  else
    echo ""
  fi
}

list_releases() {
  local current_release="$1"
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

select_latest_release() {
  find "$releases_dir" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -exec basename {} \; | sort -r | head -n 1
}

select_previous_release() {
  local current_release="$1"
  [[ -n "$current_release" ]] || { echo ""; return 0; }

  local rel
  local seen_current="false"
  while IFS= read -r rel; do
    if [[ "$seen_current" == "true" ]]; then
      echo "$rel"
      return 0
    fi
    if [[ "$rel" == "$current_release" ]]; then
      seen_current="true"
    fi
  done < <(find "$releases_dir" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -exec basename {} \; | sort -r)

  echo ""
}

write_inventory_prom() {
  local current_release="$1"
  local inventory_file="$releases_dir/version_present.prom"

  {
    echo "# HELP sppmon_release Release inventory (1 = present on disk). Label current=\"true\" marks the active release."
    echo "# TYPE sppmon_release gauge"

    local d
    for d in "$releases_dir"/*; do
      [[ -d "$d" ]] || continue
      [[ "$(basename "$d")" == .* ]] && continue

      if [[ "$(basename "$d")" == "$current_release" ]]; then
        echo "sppmon_release{release=\"$(basename "$d")\",current=\"true\"} 1"
      else
        echo "sppmon_release{release=\"$(basename "$d")\",current=\"false\"} 1"
      fi
    done
  } > "$inventory_file"

  log "Wrote release inventory: $inventory_file"
}

current_release="$(get_current_release)"

if [[ "$list_only" == "true" ]]; then
  echo ""
  echo "Base:   $base_dir"
  echo "Releases:"
  list_releases "$current_release"
  exit 0
fi

selected_release="$release_id_req"

if [[ "$use_latest" == "true" ]]; then
  selected_release="$(select_latest_release)"
  [[ -n "$selected_release" ]] || die "--latest requested but no release is available"
  log "Selected latest release: $selected_release (current was: ${current_release:-none})"
fi

if [[ "$use_previous" == "true" ]]; then
  selected_release="$(select_previous_release "$current_release")"
  [[ -n "$selected_release" ]] || die "--previous requested but no older release is available (current is oldest or not found)"
  log "Selected previous release: $selected_release (current was: ${current_release:-none})"
fi

[[ -n "$selected_release" ]] || die "No release selected (use --release, --previous, or --latest)"
[[ -d "$releases_dir/$selected_release" ]] || die "Release not found: $releases_dir/$selected_release"

# IMPORTANT: keep current symlink relative to base_dir.
ln -sfn "releases/$selected_release" "$current_link"
log "OK: current -> $(readlink "$current_link")"

write_inventory_prom "$selected_release"
REMOTE_SH
}

main() {
  parse_args "$@"
  validate_args

  local tenant
  tenant="$(resolve_tenant)"

  local host
  for host in $(normalize_list "$TARGETS_RAW"); do
    rollback_remote_host "$host" "$tenant"
  done

  if [[ "$LIST_ONLY" != "true" ]]; then
    log "Rollback completed."
  fi
}

main "$@"