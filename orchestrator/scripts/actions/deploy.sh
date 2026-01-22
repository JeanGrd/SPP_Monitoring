#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# deploy.sh
# Responsibilities:
# - Build a release tarball (bin + fragments + metadata)
# - Deploy it to one or more targets
# ------------------------------------------------------------------------------

# shellcheck disable=SC2164
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

source "$LIB_DIR/utils.sh"

# ---- Defaults ----------------------------------------------------------------

DEFAULT_REMOTE_BASE="/SPP_Monitoring"
DEFAULT_SSH_USER=""
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# ---- Parsed arguments --------------------------------------------------------

ROOT=""
APP=""
ENV_NAME=""
TARGETS_RAW=""
SERVICES_RAW=""
RESOLVED_SERVICES_RAW=""
ENABLE_REMOTE="false"
STRICT_MODE="false"
CATALOGUE_DIR=""
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
                       Uses SSH/SCP for deployment; expects key-based authentication.
  --strict             Fail build if any requested service template/binary is missing
  --services <list>    Comma-separated services to include (overrides app defaults)
  --help               Show this help

NOTES:
  - Fragments are packaged under: etc/ (flattened copy of <root>/catalogue/templates/<fragment>/ contents).
  - Fragments are selected from:   catalogue/services.yml -> services.<service>.fragments
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
  if [[ "$ENABLE_REMOTE" == "true" ]]; then
    require_cmd ssh
    require_cmd scp
  fi
  CATALOGUE_DIR="$ROOT/catalogue"
  [[ -d "$CATALOGUE_DIR" ]] || die "catalogue directory not found: $CATALOGUE_DIR"
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
  local apps_file="$CATALOGUE_DIR/apps.yml"
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
  local services_file="$CATALOGUE_DIR/services.yml"
  [[ -f "$services_file" ]] || die "services.yml not found: $services_file"

  local value
  value="$("$YQ_BIN" -r ".services.\"$svc\".requires // [] | join(\",\")" "$services_file" 2>/dev/null || true)"
  if [[ -z "$value" || "$value" == "null" ]]; then
    echo ""
    return 0
  fi
  echo "$value"
}


# --- Service name resolver for requires ---
resolve_service_name() {
  # Maps an input name to a service name.
  # - If name matches a service key: return it
  # - Else, if name matches exactly one service whose fragments contain it: return that service
  # - Else: return empty
  local name="$1"
  local services_file="$CATALOGUE_DIR/services.yml"

  local t
  t="$($YQ_BIN -r ".services.\"$name\" | type" "$services_file" 2>/dev/null || true)"
  if [[ -n "$t" && "$t" != "null" ]]; then
    echo "$name"
    return 0
  fi

  # Fallback: find a service that declares this fragment.
  local matches
  matches="$($YQ_BIN -r ".services | to_entries | map(select((.value.fragments // []) | index(\"$name\"))) | .[].key" "$services_file" 2>/dev/null || true)"
  # yq prints one per line; count
  local count
  count="$(echo "$matches" | sed '/^\s*$/d' | wc -l | tr -d '[:space:]')"
  if [[ "$count" == "1" ]]; then
    echo "$(echo "$matches" | sed '/^\s*$/d' | head -n 1)"
    return 0
  fi

  echo ""
}

resolve_services_with_requires() {
  # Expands SERVICES_RAW into RESOLVED_SERVICES_RAW by adding transitive requires.
  # Order: requirements first, then the requested service.
  local requested="$1"
  local resolved=""
  local seen=""

  _dfs_add() {
    local svc="$1"
    local mapped
    mapped="$(resolve_service_name "$svc")"
    if [[ -z "$mapped" ]]; then
      die "Unknown service or requirement '$svc' (not found as service or unique fragment in $CATALOGUE_DIR/services.yml)"
    fi
    svc="$mapped"

    # guard: avoid infinite loops / duplicates
    case " $seen " in
      *" $svc "*) return 0 ;;
    esac
    seen="$seen $svc"

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

  # Human-readable structure guide (shipped with every release)
  cat > "$pkg_dir/meta/structure.txt" <<EOF
SPP Monitoring deployment layout (target host)

<BASE>/
  releases/
    <RELEASE_ID>/
      bin/            Control scripts (control.sh, environment.sh)
      lib/            Runtime binaries shipped with the release
      etc/            Configuration fragments (flattened)
      meta/           Metadata (this manifest, structure guide)
    current -> releases/<RELEASE_ID>
  volumes/
    data/             Persistent data (WAL, buffers, etc.)
    logs/             Service logs (stdout/stderr)
    run/              PID files and runtime state

Notes:
- Releases are immutable. Rollback switches the 'current' symlink.
- Services are started from <BASE>/current using bin/control.sh.
EOF

  # --- Copy fragments per service (aggregate unique fragments) ---
  local services_file
  services_file="$CATALOGUE_DIR/services.yml"
  [[ -f "$services_file" ]] || die "services.yml not found: $services_file"
  local svc fragments_csv fragment fragments_space
  local fragments_ordered="" fragments_seen=""
  # Aggregate unique fragments (ordered)
  for svc in $(normalize_list "$RESOLVED_SERVICES_RAW"); do
    # Skip unknown entries (can happen if a requirement references a fragment name).
    if [[ "$($YQ_BIN -r ".services.\"$svc\" | type" "$services_file" 2>/dev/null || true)" == "null" ]]; then
      continue
    fi
    fragments_csv="$($YQ_BIN -r ".services.\"$svc\".fragments // [] | join(\",\")" "$services_file" 2>/dev/null || true)"
    [[ "$fragments_csv" == "null" ]] && fragments_csv=""
    fragments_space="$(echo "$fragments_csv" | tr ',' ' ' | xargs 2>/dev/null || true)"
    for fragment in $fragments_space; do
      case " $fragments_seen " in
        *" $fragment "*) : ;;
        *)
          fragments_ordered="$fragments_ordered $fragment"
          fragments_seen="$fragments_seen $fragment"
          ;;
      esac
    done
  done
  # Helper: copy an entry into etc/, handling collisions and strict mode
  _copy_into_etc() {
    local src_path="$1"
    local base dest

    base="$(basename "$src_path")"
    dest="$pkg_dir/etc/$base"

    if [[ -e "$dest" ]]; then
      if [[ "$STRICT_MODE" == "true" ]]; then
        die "Strict mode: template collision: '$base' already exists in etc/"
      fi
      warn "Template collision: '$base' already exists in etc/ (overwriting, non-strict mode)."
      rm -rf "$dest" 2>/dev/null || true
    fi

    cp -R "$src_path" "$pkg_dir/etc/"
  }

  # Now copy each fragment's contents into etc/
  for fragment in $fragments_ordered; do
    local template_src entry inner
    template_src="$CATALOGUE_DIR/templates/$fragment"
    if [[ -d "$template_src" ]]; then
      shopt -s nullglob dotglob
      for entry in "$template_src"/*; do
        if [[ -d "$entry" ]]; then
          for inner in "$entry"/*; do
            _copy_into_etc "$inner"
          done
        else
          _copy_into_etc "$entry"
        fi
      done
      shopt -u nullglob dotglob
    else
      # Only warn if the fragment was declared, not if a service has no fragments.
      if [[ "$STRICT_MODE" == "true" ]]; then
        die "Strict mode: missing fragment template directory for fragment '$fragment' (expected: $CATALOGUE_DIR/templates/$fragment)"
      fi
      warn "Missing fragment template directory for fragment '$fragment' (expected: $CATALOGUE_DIR/templates/$fragment). Continuing (non-strict mode)."
    fi
  done

  # Copy binaries as declared in catalogue/services.yml:
  #   services.<service>.binaries: ["alloy", ...]
  # This avoids assuming binary name == service name and supports config-only services (binaries: []).
  local bin_list bin_name
  for svc in $(normalize_list "$RESOLVED_SERVICES_RAW"); do
    # Always treat missing binaries as empty list (config-only allowed)
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
    # Also ship the shared runtime environment script
    if [[ -f "$ROOT/scripts/runtime/environment.sh" ]]; then
      cp "$ROOT/scripts/runtime/environment.sh" "$pkg_dir/bin/environment.sh"
    else
      if [[ "$STRICT_MODE" == "true" ]]; then
        die "Strict mode: missing shared runtime environment script (expected: $ROOT/scripts/runtime/environment.sh)"
      fi
      warn "Missing shared runtime environment script (expected: $ROOT/scripts/runtime/environment.sh). Continuing (non-strict mode)."
    fi
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


  # --- Enrich endpoints (for manifest and environment.sh) ---
  local envs_file endpoint_mimir endpoint_loki endpoint_minio
  envs_file="$CATALOGUE_DIR/envs.yml"
  endpoint_mimir=""; endpoint_loki=""; endpoint_minio=""
  if [[ -f "$envs_file" ]]; then
    endpoint_mimir="$($YQ_BIN -r ".envs.\"$ENV_NAME\".endpoint.mimir // \"\"" "$envs_file" 2>/dev/null || true)"
    endpoint_loki="$($YQ_BIN -r ".envs.\"$ENV_NAME\".endpoint.loki // \"\"" "$envs_file" 2>/dev/null || true)"
    endpoint_minio="$($YQ_BIN -r ".envs.\"$ENV_NAME\".endpoint.minio // \"\"" "$envs_file" 2>/dev/null || true)"
    [[ "$endpoint_mimir" == "null" ]] && endpoint_mimir=""
    [[ "$endpoint_loki" == "null" ]] && endpoint_loki=""
    [[ "$endpoint_minio" == "null" ]] && endpoint_minio=""
  fi

  # --- Compute runtime (launchable) services once so we can reuse them for environment.sh and manifest. ---
  # Runtime services = services present in catalogue/services.yml with a non-empty first binary.
  local runtime_line
  runtime_line=""

  {
    local _svc _exists _bin0
    for _svc in $(normalize_list "$RESOLVED_SERVICES_RAW"); do
      _exists="$($YQ_BIN -r ".services.\"${_svc}\" | type" "$services_file" 2>/dev/null || true)"
      [[ -z "$_exists" || "$_exists" == "null" ]] && continue

      _bin0="$($YQ_BIN -r ".services.\"${_svc}\".binaries[0] // \"\"" "$services_file" 2>/dev/null || true)"
      [[ "$_bin0" == "null" ]] && _bin0=""
      [[ -z "${_bin0//[[:space:]]/}" ]] && continue

      if [[ -z "$runtime_line" ]]; then
        runtime_line="$_svc"
      else
        runtime_line="$runtime_line $_svc"
      fi
    done
  }

  # --- Generate per-release environment file (bash-sourceable; Bash 3 compatible) ---
  # Only launchable services (services with at least one binary) are included.
  local env_out
  env_out="$pkg_dir/bin/environment.sh"

  # Append release-specific exports after the shared runtime environment script.
  # The shared script provides stable paths and helpers; this block provides context and service mappings.
  {
    echo
    echo "# ------------------------------------------------------------------------------"
    echo "# Release-specific context (auto-generated at build time)"
    echo "# ------------------------------------------------------------------------------"

    # Context
    echo "export SPPMON_APP=\"$APP\""
    echo "export SPPMON_ENV=\"$ENV_NAME\""

    # Endpoints (optional)
    local em_esc el_esc eni_esc
    em_esc="${endpoint_mimir//\\/\\\\}"; em_esc="${em_esc//\"/\\\"}"
    el_esc="${endpoint_loki//\\/\\\\}";  el_esc="${el_esc//\"/\\\"}"
    eni_esc="${endpoint_minio//\\/\\\\}"; eni_esc="${eni_esc//\"/\\\"}"
    echo "export SPPMON_ENDPOINT_MIMIR=\"$em_esc\""
    echo "export SPPMON_ENDPOINT_LOKI=\"$el_esc\""
    echo "export SPPMON_ENDPOINT_MINIO=\"$eni_esc\""

    echo
    echo "# Runtime services (launchable only: services with binaries)"

    local svc safe primary_bin args desc

    for svc in $runtime_line; do
      safe="$(echo "$svc" | sed -E 's/[^A-Za-z0-9_]/_/g')"

      primary_bin="$($YQ_BIN -r ".services.\"$svc\".binaries[0] // \"\"" "$services_file" 2>/dev/null || true)"
      [[ "$primary_bin" == "null" ]] && primary_bin=""

      args="$($YQ_BIN -r ".services.\"$svc\".args // \"\"" "$services_file" 2>/dev/null || true)"
      [[ "$args" == "null" ]] && args=""

      desc="$($YQ_BIN -r ".services.\"$svc\".description // \"\"" "$services_file" 2>/dev/null || true)"
      [[ "$desc" == "null" ]] && desc=""

      # Escape for bash double-quoted string literals.
      primary_bin="${primary_bin//\\/\\\\}"; primary_bin="${primary_bin//\"/\\\"}"
      args="${args//\\/\\\\}";         args="${args//\"/\\\"}"
      desc="${desc//\\/\\\\}";         desc="${desc//\"/\\\"}"

      # Emit mappings (only for runtime services; runtime_line already filters for a binary)
      echo "export SPPMON_BIN__${safe}=\"${primary_bin}\""
      echo "export SPPMON_ARGS__${safe}=\"${args}\""
      echo "export SPPMON_DESC__${safe}=\"${desc}\""
    done

    echo
    echo "export SPPMON_RUNTIME_SERVICES=\"${runtime_line}\""
  } >> "$env_out"

  chmod +x "$env_out" 2>/dev/null || true

  # Metadata (human-readable)
  # Keep it small but useful for operators: runtime services + fragments.
  local manifest_out
  manifest_out="$pkg_dir/meta/manifest.txt"

  {
    echo "Release"
    echo "  id: $release_id"
    echo "  built_at: $ts_human"
    echo
    echo "Context"
    echo "  app: $APP"
    echo "  env: $ENV_NAME"
    echo

    echo "Services"
    # List runtime services only (launchable = has binaries)
    local svc desc bins_csv bins_space
    for svc in $runtime_line; do
      desc="$($YQ_BIN -r ".services.\"$svc\".description // \"\"" "$services_file" 2>/dev/null || true)"
      [[ "$desc" == "null" ]] && desc=""
      echo "$svc: $desc"

      bins_csv="$($YQ_BIN -r ".services.\"$svc\".binaries // [] | join(\",\")" "$services_file" 2>/dev/null || true)"
      [[ "$bins_csv" == "null" ]] && bins_csv=""
      bins_space="$(echo "$bins_csv" | tr ',' ' ' | xargs 2>/dev/null || true)"
      if [[ -n "${bins_space//[[:space:]]/}" ]]; then
        echo "  binaries: $bins_space"
      fi
    done
    echo
    echo "Fragments"
    if [[ -n "${fragments_ordered//[[:space:]]/}" ]]; then
      local f
      for f in $fragments_ordered; do
        echo "  - $f"
      done
    else
      echo "  - (none)"
    fi
  } > "$manifest_out"

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

# ---- Remote deployment -------------------------------------------------------

deploy_remote_host() {
  local target_name="$1"
  local release_id="$2"
  local tarball="$3"

  local remote_base="${SPPMON_REMOTE_BASE:-$DEFAULT_REMOTE_BASE}"
  local ssh_user="${SPPMON_SSH_USER:-$DEFAULT_SSH_USER}"

  local remote_host="$target_name"
  local remote_dest="$target_name"
  if [[ -n "$ssh_user" ]]; then
    remote_dest="$ssh_user@$target_name"
  fi

  # Remote layout under <remote_base>
  local base="$remote_base"
  local releases="$base/releases"
  local volumes="$base/volumes"
  local current="$base/current"

  local remote_tmp="/tmp/${release_id}.tar.gz"
  local staging_dir="$releases/.staging_${release_id}"
  local new_release="$releases/$release_id"

  log "Deploying (remote) into: ${remote_host}${base}"

  # 1) Ensure base directories exist
  ssh $SSH_OPTS "$remote_dest" "mkdir -p '$releases' '$volumes/data' '$volumes/logs' '$volumes/run'" \
    || die "SSH mkdir failed on $remote_host"

  # 2) Upload tarball to remote tmp
  scp $SSH_OPTS "$tarball" "$remote_dest:$remote_tmp" \
    || die "SCP upload failed to $remote_host:$remote_tmp"

  # 3) Remote extract into staging, move into releases, update symlink, write prom, cleanup
  ssh $SSH_OPTS "$remote_dest" bash -s -- \
    "$release_id" "$remote_tmp" "$releases" "$current" <<'REMOTE_SH'
set -euo pipefail

release_id="$1"
remote_tmp="$2"
releases="$3"
current="$4"

staging="$releases/.staging_${release_id}"
new_release="$releases/$release_id"

rm -rf "$staging"
mkdir -p "$staging"

cleanup() {
  rm -rf "$staging" 2>/dev/null || true
}
trap cleanup ERR

# Extract
 tar -xzf "$remote_tmp" -C "$staging"

# Validate
if [[ ! -d "$staging/$release_id" ]]; then
  echo "ERROR: Extract failed; '$staging/$release_id' not found" >&2
  exit 1
fi

# Move into place (atomic enough for our use)
rm -rf "$new_release"
mv "$staging/$release_id" "$new_release"

rm -rf "$staging"
trap - ERR

# Switch current symlink only after successful install
ln -sfn "$new_release" "$current"
# Write Prometheus textfile catalogue
catalogue_file="$releases/version_present.prom"
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

# Cleanup uploaded tarball
rm -f "$remote_tmp" 2>/dev/null || true
REMOTE_SH

  log "OK (remote): current -> ${remote_base}/releases/${release_id}"
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
      deploy_remote_host "$host" "$release_id" "$tarball"
    else
      deploy_simulated_host "$host" "$release_id" "$tarball"
    fi
  done
  rm -rf "$work_dir"
  log "Deploy completed for release: $release_id"
}

main "$@"