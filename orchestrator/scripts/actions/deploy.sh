#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# deploy.sh
#
# Responsibilities:
# - Build a release tarball (bin + config + metadata)
# - Deploy it to one or more targets
#
# Simulation (no SSH):
#   If --remote is NOT provided, all targets are deployed into:
#     <repo>/host/<target><REMOTE_BASE>/
#   Example (REMOTE_BASE=/sppmon):
#     host/188.23.34.10/sppmon/{releases,volumes,current}
#
# Remote mode (SSH):
#   Explicitly enabled with --remote (kept as placeholder for now).
# ------------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
# shellcheck source=../lib/common.sh
source "$LIB_DIR/common.sh"

# ---- Defaults ----------------------------------------------------------------

DEFAULT_REMOTE_BASE="/sppmon"
DEFAULT_SSH_PORT="22"

# ---- Parsed arguments --------------------------------------------------------

ROOT=""
APP=""
ENV_NAME=""
TARGETS_RAW=""
SERVICES_RAW=""
ENABLE_REMOTE="false"
STRICT_MODE="false"

print_help() {
  cat <<'EOF'
deploy.sh - Build and deploy a release

USAGE:
  deploy.sh --root <path> --app <APP> --env <ENV> --targets <list> --services <list> [--remote] [--strict]

REQUIRED:
  --root <path>        Repository root (passed by sppmon)
  --app <name>         Application name (ICOM, Jaguar, ...)
  --env <name>         Environment (UAT, PRD, ...)
  --targets <list>     Comma-separated targets (e.g. "188.23.34.10,188.23.34.11")
  --services <list>    Comma-separated services to include (e.g. "alloy,loki_exporter")

OPTIONAL:
  --remote             Enable SSH/SCP remote deployment (disabled by default)
  --strict             Fail build if any requested service template/binary is missing
  --help               Show this help

NOTES:
  - If --remote is NOT provided, ALL targets are treated as local simulations under <repo>/host/<target>/...
  - Each deploy creates an immutable release directory and switches 'current' only after success.
  - Simulation writes <repo>/host/<target><REMOTE_BASE>/releases/version_present.prom for inventory/current tracking.
EOF
}

# ---- Argument parsing --------------------------------------------------------

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --root)     ROOT="${2:-}"; shift 2 ;;
      --app)      APP="${2:-}"; shift 2 ;;
      --env)      ENV_NAME="${2:-}"; shift 2 ;;
      --targets)  TARGETS_RAW="${2:-}"; shift 2 ;;
      --services) SERVICES_RAW="${2:-}"; shift 2 ;;
      --remote)   ENABLE_REMOTE="true"; shift ;;
      --strict)   STRICT_MODE="true"; shift ;;
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
  [[ -n "$SERVICES_RAW" ]]|| die "--services is required"

  is_valid_name "$APP"      || die "Invalid app name: $APP"
  is_valid_name "$ENV_NAME" || die "Invalid env name: $ENV_NAME"

  require_cmd tar
  require_cmd find
  require_cmd mkdir
  require_cmd rm
  require_cmd mv
  require_cmd readlink
}

# ---- Build release (stdout = data only) --------------------------------------

build_release() {
  local ts_id ts_human release_id
  local dist_dir work_dir pkg_dir tarball

  ts_id="$(release_timestamp)"
  ts_human="$(human_timestamp)"
  release_id="${APP}_${ENV_NAME}_${ts_id}"

  dist_dir="$ROOT/dist"
  work_dir="$(mktemp -d)"
  pkg_dir="$work_dir/$release_id"

  mkdir -p "$dist_dir" "$pkg_dir/bin" "$pkg_dir/config" "$pkg_dir/meta"

  log "Building release: $release_id"

  # Copy templates: template/<service>/... -> config/<service>/...
  local svc
  for svc in $(normalize_list "$SERVICES_RAW"); do
    if [[ -d "$ROOT/template/$svc" ]]; then
      mkdir -p "$pkg_dir/config/$svc"
      cp -r "$ROOT/template/$svc/." "$pkg_dir/config/$svc/"
    else
      if [[ "$STRICT_MODE" == "true" ]]; then
        die "Strict mode: missing template for service '$svc' (expected: template/$svc)"
      fi
      warn "Missing template for service '$svc' (expected: template/$svc). Continuing (non-strict mode)."
    fi
  done

  # Copy binaries: bin/<service> -> bin/<service>
  for svc in $(normalize_list "$SERVICES_RAW"); do
    if [[ -f "$ROOT/bin/$svc" ]]; then
      cp "$ROOT/bin/$svc" "$pkg_dir/bin/$svc"
      chmod +x "$pkg_dir/bin/$svc" || true
    else
      if [[ "$STRICT_MODE" == "true" ]]; then
        die "Strict mode: missing binary for service '$svc' (expected: bin/$svc)"
      fi
      warn "Missing binary for service '$svc' (expected: bin/$svc). Continuing (non-strict mode)."
    fi
  done

  # Metadata
  cat > "$pkg_dir/meta/manifest.txt" <<EOF
release_id=$release_id
app=$APP
env=$ENV_NAME
built_at=$ts_human
services=$SERVICES_RAW
EOF

  ( cd "$pkg_dir" && find . -type f | sort ) > "$pkg_dir/meta/files.txt"

  tarball="$dist_dir/${release_id}.tar.gz"

  # IMPORTANT: use -C to guarantee the tarball contains only relative paths
  tar -czf "$tarball" -C "$work_dir" "$release_id"

  log "Release packaged: $tarball"

  # Return values via stdout (safe because logs are stderr)
  printf '%s|%s|%s\n' "$release_id" "$tarball" "$work_dir"
}

# ---- Local simulation deploy -------------------------------------------------

deploy_simulated_host() {
  local target_name="$1"
  local release_id="$2"
  local tarball="$3"

  local simulated_host_root="$ROOT/host/$target_name"
  local remote_base="${SPPMON_REMOTE_BASE:-$DEFAULT_REMOTE_BASE}"

  # Final base path (simulation): <repo>/host/<target><REMOTE_BASE>
  local base="$simulated_host_root$remote_base"
  [[ "$base" == "$simulated_host_root"* ]] || die "Refusing to deploy outside simulated host root: base=$base"

  local releases="$base/releases"
  local volumes="$base/volumes"
  local current="$base/current"

  local staging="$releases/.staging_${release_id}"
  local new_release="$releases/$release_id"

  log "Deploying (simulation) into: $base"
  mkdir -p "$releases" "$volumes/data" "$volumes/logs"

  # Ensure staging is clean
  rm -rf "$staging"
  mkdir -p "$staging"

  cleanup_staging() { rm -rf "$staging" || true; }
  trap cleanup_staging ERR

  # Extract into staging
  tar -xzf "$tarball" -C "$staging"

  # Tarball must contain a top-level folder named <release_id>
  [[ -d "$staging/$release_id" ]] || die "Local extract failed: $staging/$release_id not found"

  # Atomic move into place
  rm -rf "$new_release"
  mv "$staging/$release_id" "$new_release"

  # Success: remove staging and release trap
  rm -rf "$staging"
  trap - ERR

  # Switch current symlink only after successful install
  ln -sfn "$new_release" "$current"
  log "OK (simulation): current -> $(readlink "$current")"

  # Write inventory Prometheus textfile
  local inventory_file="$releases/version_present.prom"
  local current_basename
  current_basename="$(basename "$(readlink "$current")")"

  {
    echo "# HELP sppmon_release Release inventory (1 = present on disk). Label current=\"true\" marks the active release."
    echo "# TYPE sppmon_release gauge"

    for d in "$releases"/*; do
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

# ---- Remote placeholder ------------------------------------------------------

deploy_remote_placeholder() {
  warn "Remote deployment requested but SSH/SCP is currently disabled."
  warn "Enable the SSH block when ready."
}

# ---- Main --------------------------------------------------------------------

main() {
  parse_args "$@"
  validate_args

  if [[ "$STRICT_MODE" != "true" ]]; then
    log "Non-strict mode: missing templates/binaries are warnings; tarball is still created. Use --strict to fail fast."
  fi

  local result release_id tarball work_dir
  result="$(build_release)"
  release_id="${result%%|*}"
  tarball="${result#*|}"; tarball="${tarball%%|*}"
  work_dir="${result##*|}"

  local host
  for host in $(normalize_list "$TARGETS_RAW"); do
    log "Deploy target: $host"
    if [[ "$ENABLE_REMOTE" == "true" ]]; then
      deploy_remote_placeholder
    else
      deploy_simulated_host "$host" "$release_id" "$tarball"
    fi
  done

  rm -rf "$work_dir"
  log "Deploy completed for release: $release_id"
}

main "$@"