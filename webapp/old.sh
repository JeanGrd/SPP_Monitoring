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
#     <root>/hosts/<target><REMOTE_BASE>/
#   Example (REMOTE_BASE=/sppmon):
#     hosts/188.23.34.10/sppmon/{releases,volumes,current}
#
# Remote mode (SSH):
#   Explicitly enabled with --remote (kept as placeholder for now).
# ------------------------------------------------------------------------------

# shellcheck disable=SC2164
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
# shellcheck source=../lib/utils.sh
source "$LIB_DIR/utils.sh"

# ---- Defaults ----------------------------------------------------------------

DEFAULT_REMOTE_BASE="/sppmon"

# ---- Parsed arguments --------------------------------------------------------

ROOT=""
APP=""
ENV_NAME=""
TARGETS_RAW=""
SERVICES_RAW=""
RESOLVED_SERVICES_RAW=""
ENABLE_REMOTE="false"
STRICT_MODE="false"
catalogue_DIR=""
YQ_BIN=""

print_help() {
  cat <<'EOF'
deploy.sh - Build and deploy a release

USAGE:
  deploy.sh --root <path> --app <APP> --env <ENV> --targets <list> [--services <list>] [--remote] [--strict]

REQUIRED:
  --root <path>        Repository root (passed by sppmon)
  --app <name>         Application name (ICOM, Jaguar, ...)
  --env <name>         Environment (UAT, PRD, ...)
  --targets <list>     Comma-separated targets (e.g. "188.23.34.10,188.23.34.11")

OPTIONAL:
  --remote             Enable SSH/SCP remote deployment (disabled by default)
  --strict             Fail build if any requested service template/binary is missing
  --services <list>    Comma-separated services to include (overrides app defaults)
  --help               Show this help

NOTES:
  - Templates are packaged under: etc/ (flattened copy of <root>/catalogue/templates/<service>/ contents).
  - Binaries are sourced from:   <root>/bin/<name> and packaged under lib/ in the release.
  - If --remote is NOT provided, ALL targets are treated as local simulations under <root>/hosts/<target>/...
  - Simulation writes <root>/hosts/<target><REMOTE_BASE>/releases/version_present.prom for catalogue/current tracking.
  - Each release includes: bin/control.sh, bin/readme.txt (usage guide), and bin/environment.sh (machine-readable service runtime info).
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

  is_valid_name "$APP"      || die "Invalid app name: $APP"
  is_valid_name "$ENV_NAME" || die "Invalid env name: $ENV_NAME"

  require_cmd tar
  require_cmd find
  require_cmd mkdir
  require_cmd rm
  require_cmd mv
  require_cmd readlink

  detect_catalogue_dir
}

detect_catalogue_dir() {
  # catalogue is expected at <orchestrator>/catalogue.
  local inv="$ROOT/catalogue"
  if [[ -d "$inv" ]]; then
    catalogue_DIR="$inv"
    return 0
  fi

  die "catalogue directory not found: $inv"
}

detect_yq() {
  # Prefer a vendored yq binary if present under <root>/tools.
  local candidate=""

  # Fallback: accept other naming conventions (e.g. yq_darwin_amd64) under tools/.
  if [[ -d "$ROOT/tools" ]]; then
    candidate="$(find "$ROOT/tools" -maxdepth 1 -type f -name 'yq*' 2>/dev/null | head -n 1 || true)"
    if [[ -n "$candidate" ]]; then
      if [[ ! -x "$candidate" ]]; then
        chmod +x "$candidate" 2>/dev/null || true
      fi
      if [[ -x "$candidate" ]]; then
        YQ_BIN="$candidate"
        return 0
      fi
    fi
  fi

  # Last resort: system yq.
  if command -v yq >/dev/null 2>&1; then
    YQ_BIN="yq"
    return 0
  fi

  die "yq is required to read catalogue YAML. Install yq or vendor it at <root>/tools/yq (ensure it is executable)"
}

load_default_services_for_app() {
  # Reads apps.<APP>.defaults.services from catalogue/apps.yml.
  # Tries the provided APP key first, then common case variants.
  local app="$APP"
  local apps_file="$catalogue_DIR/apps.yml"
  [[ -f "$apps_file" ]] || die "apps.yml not found: $apps_file"

  local q value
  for q in "$app" "$(echo "$app" | tr '[:lower:]' '[:upper:]')" "$(echo "$app" | tr '[:upper:]' '[:lower:]')"; do
    value="$("$YQ_BIN" -r ".apps.\"$q\".defaults.services | join(\",\")" "$apps_file" 2>/dev/null || true)"
    if [[ -n "$value" && "$value" != "null" ]]; then
      SERVICES_RAW="$value"
      return 0
    fi
  done

  die "No default services found for app '$APP' in $apps_file (expected: apps.<APP>.defaults.services)"
}

load_service_requires() {
  # Reads services.<service>.requires from catalogue/services.yml.
  # Returns a comma-separated list (may be empty if no requirements).
  local svc="$1"
  local services_file="$catalogue_DIR/services.yml"
  [[ -f "$services_file" ]] || die "services.yml not found: $services_file"

  local value
  value="$("$YQ_BIN" -r ".services.\"$svc\".requires // [] | join(\",\")" "$services_file" 2>/dev/null || true)"
  if [[ -z "$value" || "$value" == "null" ]]; then
    echo ""
    return 0
  fi
  echo "$value"
}

resolve_services_with_requires() {
  # Expands SERVICES_RAW into RESOLVED_SERVICES_RAW by adding transitive requires.
  # Order: requirements first, then the requested service.
  local requested="$1"
  local resolved=""
  local seen=""

  _dfs_add() {
    local svc="$1"

    # guard: avoid infinite loops / duplicates
    case " $seen " in
      *" $svc "*) return 0 ;;
    esac
    seen="$seen $svc"

    # validate service exists (services.<svc> present)
    local exists
    exists="$("$YQ_BIN" -r ".services.\"$svc\" | type" "$catalogue_DIR/services.yml" 2>/dev/null || true)"
    if [[ -z "$exists" || "$exists" == "null" ]]; then
      die "Unknown service '$svc' (not found in $catalogue_DIR/services.yml)"
    fi

    local reqs
    reqs="$(load_service_requires "$svc")"
    if [[ -n "$reqs" ]]; then
      local r
      for r in $(normalize_list "$reqs"); do
        _dfs_add "$r"
      done
    fi

    # append to resolved if not already present (preserve order)
    case " $resolved " in
      *" $svc "*) : ;;
      *) resolved="$resolved $svc" ;;
    esac
  }

  local svc
  for svc in $(normalize_list "$requested"); do
    _dfs_add "$svc"
  done

  # normalize to comma-separated list
  echo "$resolved" | tr ' ' '\n' | sed '/^\s*$/d' | paste -sd ',' -
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

  mkdir -p "$dist_dir" "$pkg_dir/bin" "$pkg_dir/lib" "$pkg_dir/etc" "$pkg_dir/meta"

  log "Building release: $release_id"

  # Copy templates per service -> etc/
  # We flatten template contents into a single etc/ directory.
  # This keeps the runtime layout simple (Alloy can point to a single config dir),
  # but requires avoiding filename collisions across services.
  local svc template_src
  for svc in $(normalize_list "$RESOLVED_SERVICES_RAW"); do
    template_src="$catalogue_DIR/templates/$svc"
    if [[ -d "$template_src" ]]; then
      # Copy each entry from the service template dir into etc/
      local entry base dest
      shopt -s nullglob dotglob
      for entry in "$template_src"/*; do
        base="$(basename "$entry")"
        dest="$pkg_dir/etc/$base"

        if [[ -e "$dest" ]]; then
          if [[ "$STRICT_MODE" == "true" ]]; then
            die "Strict mode: template collision for service '$svc': '$base' already exists in etc/"
          fi
          warn "Template collision for service '$svc': '$base' already exists in etc/ (overwriting, non-strict mode)."
          rm -rf "$dest" 2>/dev/null || true
        fi

        # Preserve directories and files.
        cp -R "$entry" "$pkg_dir/etc/"
      done
      shopt -u nullglob dotglob
    else
      if [[ "$STRICT_MODE" == "true" ]]; then
        die "Strict mode: missing template for service '$svc' (expected: orchestrator/catalogue/templates/$svc)"
      fi
      warn "Missing template for service '$svc' (expected: orchestrator/catalogue/templates/$svc). Continuing (non-strict mode)."
    fi
  done

  # Copy binaries as declared in catalogue/services.yml:
  #   services.<service>.binaries: ["alloy", ...]
  # This avoids assuming binary name == service name and supports config-only services (binaries: []).
  local svc bin_list bin_name services_file
  services_file="$catalogue_DIR/services.yml"
  [[ -f "$services_file" ]] || die "services.yml not found: $services_file"

  for svc in $(normalize_list "$RESOLVED_SERVICES_RAW"); do
    # Detect presence of the key first; empty list means "config-only".
    local bin_type
    bin_type="$($YQ_BIN -r ".services.\"$svc\".binaries | type" "$services_file" 2>/dev/null || true)"

    if [[ -z "$bin_type" || "$bin_type" == "null" ]]; then
      if [[ "$STRICT_MODE" == "true" ]]; then
        die "Strict mode: service '$svc' is missing 'binaries' in $services_file (expected: services.$svc.binaries)"
      fi
      warn "Service '$svc' is missing 'binaries' in $services_file (expected even if empty list for config-only services). Continuing (non-strict mode)."
      continue
    fi

    # Now read the list. For [] this yields an empty string.
    bin_list="$($YQ_BIN -r ".services.\"$svc\".binaries // [] | join(\",\")" "$services_file" 2>/dev/null || true)"
    [[ "$bin_list" == "null" ]] && bin_list=""

    # Config-only service: no binaries to ship.
    if [[ -z "$(echo "$bin_list" | tr -d '[:space:]')" ]]; then
      continue
    fi

    for bin_name in $(normalize_list "$bin_list"); do
      if [[ -f "$ROOT/bin/$bin_name" ]]; then
        cp "$ROOT/bin/$bin_name" "$pkg_dir/lib/$bin_name"
        chmod +x "$pkg_dir/lib/$bin_name" || true
      else
        if [[ "$STRICT_MODE" == "true" ]]; then
          die "Strict mode: missing binary '$bin_name' for service '$svc' (expected: <repo>/bin/$bin_name)"
        fi
        warn "Missing binary '$bin_name' for service '$svc' (expected: <repo>/bin/$bin_name). Continuing (non-strict mode)."
      fi
    done
  done

  # Include runtime control plane (shipped with every release)
  # Target (release): bin/control.sh and bin/readme.txt (or CONTROL.txt)
  if [[ -f "$ROOT/scripts/runtime/control.sh" ]]; then
    cp "$ROOT/scripts/runtime/control.sh" "$pkg_dir/bin/control.sh"
    chmod +x "$pkg_dir/bin/control.sh" || true
  else
    if [[ "$STRICT_MODE" == "true" ]]; then
      die "Strict mode: missing runtime control script (expected: $ROOT/scripts/runtime/control.sh)"
    fi
    warn "Missing runtime control script (expected: $ROOT/scripts/runtime/control.sh). Continuing (non-strict mode)."
  fi

  if [[ -f "$ROOT/scripts/runtime/readme.txt" ]]; then
    cp "$ROOT/scripts/runtime/readme.txt" "$pkg_dir/bin/readme.txt"
  elif [[ -f "$ROOT/scripts/runtime/CONTROL.txt" ]]; then
    cp "$ROOT/scripts/runtime/CONTROL.txt" "$pkg_dir/bin/CONTROL.txt"
  else
    if [[ "$STRICT_MODE" == "true" ]]; then
      die "Strict mode: missing control documentation (expected: $ROOT/scripts/runtime/readme.txt or CONTROL.txt)"
    fi
    warn "Missing control documentation (expected: $ROOT/scripts/runtime/readme.txt or CONTROL.txt). Continuing (non-strict mode)."
  fi

  # Generate runtime environment (bash-sourceable; Bash 3 compatible)
  # Only launchable services (services with at least one binary) are included.
  local env_out
  env_out="$pkg_dir/bin/environment.sh"

  {
    echo "#!/usr/bin/env bash"
    echo
    echo "# Auto-generated runtime mapping for this release"
    echo "# Bash 3 compatible"
    echo "#"
    echo "# Variables:"
    echo "#   SPPMON_RUNTIME_SERVICES=\"svc1 svc2\""
    echo "#   SPPMON_BIN__<svc>=\"binary\""
    echo "#   SPPMON_ARGS__<svc>=\"args\""
    echo

    echo "# Paths (relative to release root unless absolute)"
    echo "export SPPMON_RELEASE_DIR=\".\""
    echo "export SPPMON_ETC_DIR=\"etc\""
    echo "export SPPMON_LIB_DIR=\"lib\""
    echo "export SPPMON_VOLUMES_DIR=\"../volumes\""
    echo "export SPPMON_DATA_DIR=\"../volumes/data\""
    echo "export SPPMON_LOG_DIR=\"../volumes/logs\""
    echo "export SPPMON_RUN_DIR=\"../volumes/run\""
    echo
    echo "# Services list"

    local runtime_line=""

    for svc in $(normalize_list "$RESOLVED_SERVICES_RAW"); do
      local safe bins_csv bins_space primary_bin args

      # Read binaries list (space-separated). Empty => config-only => skip.
      bins_csv="$($YQ_BIN -r ".services.\"$svc\".binaries // [] | join(\",\")" "$services_file" 2>/dev/null || true)"
      [[ "$bins_csv" == "null" ]] && bins_csv=""
      bins_space="$(echo "$bins_csv" | tr ',' ' ' | xargs 2>/dev/null || true)"

      if [[ -z "${bins_space//[[:space:]]/}" ]]; then
        continue
      fi

      primary_bin="$(echo "$bins_space" | awk '{print $1}')"

      # Guard: skip if primary_bin is empty after trimming
      if [[ -z "${primary_bin//[[:space:]]/}" ]]; then
        continue
      fi

      # Read args (string). Missing/null => empty.
      args="$($YQ_BIN -r ".services.\"$svc\".args // \"\"" "$services_file" 2>/dev/null || true)"
      [[ "$args" == "null" ]] && args=""

      # SAFE key: non [A-Za-z0-9_] replaced with underscore.
      safe="$(echo "$svc" | sed -E 's/[^A-Za-z0-9_]/_/g')"

      # Escape for bash double-quoted string literals.
      primary_bin="${primary_bin//\\/\\\\}"
      primary_bin="${primary_bin//\"/\\\"}"
      args="${args//\\/\\\\}"
      args="${args//\"/\\\"}"

      echo "export SPPMON_BIN__${safe}=\"${primary_bin}\""
      echo "export SPPMON_ARGS__${safe}=\"${args}\""
      echo

      if [[ -z "$runtime_line" ]]; then
        runtime_line="$svc"
      else
        runtime_line="$runtime_line $svc"
      fi
    done

    echo "export SPPMON_RUNTIME_SERVICES=\"${runtime_line}\""

  } > "$env_out"

  chmod +x "$env_out" || true

  # Metadata
  cat > "$pkg_dir/meta/manifest.txt" <<EOF
release_id=$release_id
app=$APP
env=$ENV_NAME
built_at=$ts_human
services=$RESOLVED_SERVICES_RAW
EOF

  ( cd "$pkg_dir" && find . -type f | sort ) > "$pkg_dir/meta/files.txt"

  # Update any runtime.env config path from config/ to etc/
  if [[ -f "$pkg_dir/meta/runtime.env" ]]; then
    # Only replace config/ with etc/ in ARGS or path values
    sed -i.bak 's/config\//etc\//g' "$pkg_dir/meta/runtime.env" && rm -f "$pkg_dir/meta/runtime.env.bak"
  fi

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

  local simulated_host_root="$ROOT/hosts/$target_name"
  local remote_base="${SPPMON_REMOTE_BASE:-$DEFAULT_REMOTE_BASE}"

  # Final base path (simulation): <root>/host/<target><REMOTE_BASE>
  local base="$simulated_host_root$remote_base"
  [[ "$base" == "$simulated_host_root"* ]] || die "Refusing to deploy outside simulated host root: base=$base"

  local releases="$base/releases"
  local volumes="$base/volumes"
  local current="$base/current"

  local staging="$releases/.staging_${release_id}"
  local new_release="$releases/$release_id"

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

      # Write catalogue Prometheus textfile
  local catalogue_file="$releases/version_present.prom"
  local current_basename
  current_basename="$(basename "$(readlink "$current")")"

  {
    echo "# HELP sppmon_release Release catalogue (1 = present on disk). Label current=\"true\" marks the active release."
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
  } > "$catalogue_file"

      log "Wrote release catalogue: $catalogue_file"
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

  detect_yq

  if [[ -z "${SERVICES_RAW:-}" ]]; then
    log "No --services provided; using defaults from catalogue/apps.yml for app '$APP'."
    load_default_services_for_app
    log "Resolved default services: $SERVICES_RAW"
  fi

  # Always expand transitive dependencies (requires) before building the release.
  RESOLVED_SERVICES_RAW="$(resolve_services_with_requires "$SERVICES_RAW")"
  log "Resolved services (with requires): $RESOLVED_SERVICES_RAW"

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