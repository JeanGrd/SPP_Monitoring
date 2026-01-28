#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC2164
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
source "$LIB_DIR/utils.sh"

ROOT=""          # repo root (passed by sppmon)
APP=""           # ICOM, Jaguar, ...
ENV_NAME=""      # UAT, PRD, ...
TENANT=""        # ssh user
TARGETS_RAW=""   # comma list
SERVICES_RAW=""  # comma list (optional), supports svc@ver

REMOTE_BASE_DEFAULT="SPP_Monitoring"   # relative to remote login dir
SSH_OPTS="-o StrictHostKeyChecking=no"

CATALOGUE=""
YQ=""

help() {
  cat <<'EOF'
Deploy a release (remote).

USAGE:
  deploy.sh --root <path> --app <APP> --env <ENV> --tenant <SSH_USER> --targets <t1,t2> [--services <svc1,svc2|svc@ver>]

REQUIRED:
  --app, --env, --tenant, --targets

OPTIONAL:
  --services   If omitted, defaults come from catalogue/apps.yml -> apps.<APP>.defaults.services

NOTES:
  - Binaries are sourced from: <root>/bin/<binary>/<version>/<binary>
  - Fragments are copied from: <root>/catalogue/templates/<fragment>/ (contents flattened into etc/)
  - Endpoints are read from:   <root>/catalogue/envs.yml -> envs.<ENV>.endpoint.{mimir,loki,minio}
EOF
}

parse() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --root) ROOT="${2:-}"; shift 2 ;;
      --app) APP="${2:-}"; shift 2 ;;
      --env) ENV_NAME="${2:-}"; shift 2 ;;
      --tenant) TENANT="${2:-}"; shift 2 ;;
      --targets) TARGETS_RAW="${2:-}"; shift 2 ;;
      --services) SERVICES_RAW="${2:-}"; shift 2 ;;
      --help|-h) help; exit 0 ;;
      *) die "Unknown argument: $1 (use --help)" ;;
    esac
  done
}

need() {
  local v="$1"; local name="$2"
  [[ -n "${v//[[:space:]]/}" ]] || die "$name is required"
}

init() {
  need "$ROOT" "--root"
  need "$APP" "--app"
  need "$ENV_NAME" "--env"
  need "$TENANT" "--tenant"
  need "$TARGETS_RAW" "--targets"

  CATALOGUE="$ROOT/catalogue"
  [[ -d "$CATALOGUE" ]] || die "catalogue not found: $CATALOGUE"

  YQ="$ROOT/tools/yq"
  [[ -x "$YQ" ]] || die "yq not found/executable at: $YQ"
}

# -------- catalogue helpers --------

yq_svc_exists() {
  local svc="$1"
  local t
  t="$($YQ -r ".services.\"$svc\" | type" "$CATALOGUE/services.yml")"
  [[ "$t" != "null" ]]
}

# Map a fragment name -> service name if it matches exactly one service.fragments entry.
fragment_to_service() {
  local frag="$1"
  local matches count
  matches="$($YQ -r '.services | to_entries | map(select((.value.fragments // []) | index('"\"$frag\""'))) | .[].key' "$CATALOGUE/services.yml" || true)"
  count="$(echo "$matches" | sed '/^\s*$/d' | wc -l | tr -d '[:space:]')"
  [[ "$count" == "1" ]] && echo "$(echo "$matches" | sed '/^\s*$/d' | head -n1)" || echo ""
}

svc_requires_csv() {
  local svc="$1"
  $YQ -r ".services.\"$svc\".requires // [] | join(\",\")" "$CATALOGUE/services.yml"
}

svc_fragments_csv() {
  local svc="$1"
  $YQ -r ".services.\"$svc\".fragments // [] | join(\",\")" "$CATALOGUE/services.yml"
}

svc_desc() {
  local svc="$1"
  $YQ -r ".services.\"$svc\".description // \"\"" "$CATALOGUE/services.yml"
}

svc_args() {
  local svc="$1"
  $YQ -r ".services.\"$svc\".args // \"\"" "$CATALOGUE/services.yml"
}

svc_bin_name() {
  local svc="$1"
  $YQ -r ".services.\"$svc\".binary.name // \"\"" "$CATALOGUE/services.yml"
}

svc_bin_default_version() {
  local svc="$1"
  $YQ -r ".services.\"$svc\".binary.default_version // \"\"" "$CATALOGUE/services.yml"
}

svc_bin_versions_csv() {
  local svc="$1"
  $YQ -r ".services.\"$svc\".binary.available_versions // [] | join(\",\")" "$CATALOGUE/services.yml"
}

app_defaults_csv() {
  $YQ -r ".apps.\"$APP\".defaults.services // [] | join(\",\")" "$CATALOGUE/apps.yml"
}

env_endpoint() {
  local key="$1" # mimir|loki|minio
  if [[ -f "$CATALOGUE/envs.yml" ]]; then
    $YQ -r ".envs.\"$ENV_NAME\".endpoint.$key // \"\"" "$CATALOGUE/envs.yml"
  else
    echo ""
  fi
}

# -------- services parsing/expansion --------

trim() {
  local s="$1"
  s="${s#${s%%[![:space:]]*}}"
  s="${s%${s##*[![:space:]]}}"
  printf '%s' "$s"
}

# Parse SERVICES_RAW into two globals:
# - SERVICES_LIST="svc1 svc2"
# - OVERRIDES="svc=ver svc=ver"
SERVICES_LIST=""
OVERRIDES=""

parse_services() {
  local input="$1"
  SERVICES_LIST=""; OVERRIDES=""

  local IFS=',' entry svc ver
  for entry in $input; do
    entry="$(trim "$entry")"
    [[ -n "$entry" ]] || continue

    if [[ "$entry" == *"@"* ]]; then
      svc="${entry%%@*}"; ver="${entry#*@}"
      [[ -n "$svc" ]] || die "Invalid service token: '$entry'"
      SERVICES_LIST+="${SERVICES_LIST:+ }$svc"
      [[ -n "$ver" ]] && OVERRIDES+="${OVERRIDES:+ }$svc=$ver"
    else
      SERVICES_LIST+="${SERVICES_LIST:+ }$entry"
    fi
  done

  [[ -n "$SERVICES_LIST" ]] || die "No services selected"
}

override_for() {
  local svc="$1" pair
  for pair in $OVERRIDES; do
    [[ "$pair" == "$svc="* ]] && { echo "${pair#*=}"; return 0; }
  done
  echo ""
}

# Expand requires transitively. Accept requires entries as:
# - service names
# - OR fragment names (mapped to a unique service)
expand_services() {
  local seen="" out=""

  _add() {
    local name="$1" svc reqs r mapped

    if yq_svc_exists "$name"; then
      svc="$name"
    else
      mapped="$(fragment_to_service "$name")"
      [[ -n "$mapped" ]] || die "Unknown service/requirement '$name' (not a service key and not a unique fragment)"
      svc="$mapped"
    fi

    case " $seen " in *" $svc "*) return 0 ;; esac
    seen="$seen $svc"

    reqs="$(svc_requires_csv "$svc")"
    if [[ -n "${reqs//[[:space:]]/}" ]]; then
      for r in $(echo "$reqs" | tr ',' ' '); do
        [[ -n "$r" ]] || continue
        _add "$r"
      done
    fi

    out+="${out:+ }$svc"
  }

  local s
  for s in $SERVICES_LIST; do
    _add "$s"
  done

  echo "$out"
}

# -------- build release --------

copy_fragment_dir_flat() {
  local frag="${1:-}" src dst
  dst="$2"
  [[ -n "${frag//[[:space:]]/}" ]] || die "Empty fragment name"
  src="$CATALOGUE/templates/$frag"
  [[ -d "$src" ]] || die "Missing fragment template: $src"

  shopt -s nullglob dotglob
  local p
  for p in "$src"/*; do
    cp -R "$p" "$dst/"
  done
  shopt -u nullglob dotglob
}

copy_binary_for_service() {
  local svc="$1" libdst="$2"
  local bin ver versions override src

  bin="$(svc_bin_name "$svc")"
  [[ -n "${bin//[[:space:]]/}" ]] || return 0  # config-only

  override="$(override_for "$svc")"
  ver="$override"
  [[ -n "${ver//[[:space:]]/}" ]] || ver="$(svc_bin_default_version "$svc")"
  [[ -n "${ver//[[:space:]]/}" ]] || die "No version for binary '$bin' in service '$svc'"

  versions="$(svc_bin_versions_csv "$svc")"
  if [[ -n "${versions//[[:space:]]/}" ]]; then
    local ok=no v
    for v in $(echo "$versions" | tr ',' ' '); do
      [[ "$v" == "$ver" ]] && ok=yes
    done
    [[ "$ok" == yes ]] || die "Version '$ver' not allowed for '$svc' (allowed: $versions)"
  fi

  src="$ROOT/bin/$bin/$ver/$bin"
  [[ -f "$src" ]] || die "Missing binary for '$svc': $src"
  cp "$src" "$libdst/$bin"
  chmod +x "$libdst/$bin" || true
}

build_release() {
  local ts_id ts_human rid work pkg dist tar

  ts_id="$(release_timestamp)"
  ts_human="$(human_timestamp)"
  rid="${APP}_${ENV_NAME}_${ts_id}"

  dist="$ROOT/dist"; mkdir -p "$dist"
  work="$(mktemp -d)"
  pkg="$work/$rid"

  mkdir -p "$pkg/bin" "$pkg/lib" "$pkg/etc" "$pkg/meta"

  # fragments: union of selected services.fragments (unique, ordered)
  local frags_seen="" frags="" svc fcsv f
  for svc in $EXPANDED_SERVICES; do
    fcsv="$(svc_fragments_csv "$svc")"
    for f in $(echo "$fcsv" | tr ',' ' '); do
      [[ -n "$f" ]] || continue
      case " $frags_seen " in *" $f "*) : ;; *) frags_seen="$frags_seen $f"; frags+="${frags:+ }$f" ;; esac
    done
  done

  for f in $frags; do
    copy_fragment_dir_flat "$f" "$pkg/etc"
  done

  # binaries
  for svc in $EXPANDED_SERVICES; do
    copy_binary_for_service "$svc" "$pkg/lib"
  done

  # runtime scripts (shipped per release)
  [[ -f "$ROOT/scripts/runtime/control.sh" ]] || die "Missing: $ROOT/scripts/runtime/control.sh"
  [[ -f "$ROOT/scripts/runtime/environment.sh" ]] || die "Missing: $ROOT/scripts/runtime/environment.sh"
  cp "$ROOT/scripts/runtime/control.sh" "$pkg/bin/control.sh"
  chmod +x "$pkg/bin/control.sh" || true
  cp "$ROOT/scripts/runtime/environment.sh" "$pkg/bin/environment.sh"

  # release-specific exports appended to bin/environment.sh
  local em el eni
  em="$(env_endpoint mimir)"
  el="$(env_endpoint loki)"
  eni="$(env_endpoint minio)"

  # runtime services = services that have a binary
  local runtime="" b
  for svc in $EXPANDED_SERVICES; do
    b="$(svc_bin_name "$svc")"
    [[ -n "${b//[[:space:]]/}" ]] || continue
    runtime+="${runtime:+ }$svc"
  done

  {
    echo
    echo "# ------------------------------------------------------------------------------"
    echo "# Release-specific context (auto-generated at build time)"
    echo "# ------------------------------------------------------------------------------"
    echo "export SPPMON_APP=\"$APP\""
    echo "export SPPMON_ENV=\"$ENV_NAME\""
    echo "export SPPMON_ENDPOINT_MIMIR=\"${em//\"/\\\"}\""
    echo "export SPPMON_ENDPOINT_LOKI=\"${el//\"/\\\"}\""
    echo "export SPPMON_ENDPOINT_MINIO=\"${eni//\"/\\\"}\""
    echo
    for svc in $runtime; do
      local safe desc args binname
      safe="$(echo "$svc" | sed -E 's/[^A-Za-z0-9_]/_/g')"
      binname="$(svc_bin_name "$svc")"
      args="$(svc_args "$svc")"
      desc="$(svc_desc "$svc")"
      echo "export SPPMON_BIN__${safe}=\"${binname//\"/\\\"}\""
      echo "export SPPMON_ARGS__${safe}=\"${args//\"/\\\"}\""
      echo "export SPPMON_DESC__${safe}=\"${desc//\"/\\\"}\""
    done
    echo
    echo "export SPPMON_RUNTIME_SERVICES=\"$runtime\""
  } >> "$pkg/bin/environment.sh"

  # manifest (compact + readable)
  {
    echo "Release"
    echo "  id: $rid"
    echo "  built_at: $ts_human"
    echo
    echo "Context"
    echo "  app: $APP"
    echo "  env: $ENV_NAME"
    echo
    echo "Services"
    for svc in $runtime; do
      echo "$svc: $(svc_desc "$svc")"
    done
    echo
    echo "Fragments"
    for f in $frags; do
      echo "  - $f"
    done
  } > "$pkg/meta/manifest.txt"

  tar="$dist/$rid.tar.gz"
  tar -czf "$tar" -C "$work" "$rid"

  log "Release packaged: $tar"
  printf '%s|%s|%s\n' "$rid" "$tar" "$work"
}

# -------- remote deploy --------

remote_base() {
  local b="${SPPMON_REMOTE_BASE:-$REMOTE_BASE_DEFAULT}"
  b="${b%/}"; b="${b#/}"
  [[ -n "${b//[[:space:]]/}" ]] || die "Remote base is empty"
  echo "$b"
}

deploy_one() {
  local host="$1" rid="$2" tar="$3"
  local base rel vol cur tmp dest

  base="$(remote_base)"
  rel="$base/releases"
  vol="$base/volumes"
  cur="$base/current"
  tmp="/tmp/$rid.tar.gz"
  dest="$TENANT@$host"

  log "Deploying: $host:$base"

  ssh $SSH_OPTS "$dest" "mkdir -p '$rel' '$vol/data' '$vol/logs' '$vol/run'" || die "SSH mkdir failed: $host"
  scp $SSH_OPTS "$tar" "$dest:$tmp" || die "SCP failed: $host"

  ssh $SSH_OPTS "$dest" bash -s -- "$rid" "$tmp" "$rel" <<'REMOTE'
set -euo pipefail
rid="$1"; tmp="$2"; rel="$3"
base_dir="$(dirname "$rel")"
staging="$rel/.staging_${rid}"
new="$rel/$rid"

rm -rf "$staging"
mkdir -p "$staging"
trap 'rm -rf "$staging" 2>/dev/null || true' ERR

tar -xzf "$tmp" -C "$staging"
[[ -d "$staging/$rid" ]] || { echo "ERROR: extract failed" >&2; exit 1; }

rm -rf "$new"
mv "$staging/$rid" "$new"
rm -rf "$staging"
trap - ERR

# current symlink must be relative to <BASE>
ln -sfn "releases/$rid" "$base_dir/current"

# prom catalogue
releases_dir="$rel"
cur_id="$(basename "$(readlink "$base_dir/current")")"
{
  echo "# HELP sppmon_release Release catalogue (1 = present). current=\"true\" for active release."
  echo "# TYPE sppmon_release gauge"
  for d in "$releases_dir"/*; do
    [[ -d "$d" ]] || continue
    [[ "$(basename "$d")" == .* ]] && continue
    if [[ "$(basename "$d")" == "$cur_id" ]]; then
      echo "sppmon_release{release=\"$(basename "$d")\",current=\"true\"} 1"
    else
      echo "sppmon_release{release=\"$(basename "$d")\",current=\"false\"} 1"
    fi
  done
} > "$releases_dir/version_present.prom"

rm -f "$tmp" 2>/dev/null || true
REMOTE

  log "OK: $host current -> $rid"
}

main() {
  parse "$@"
  init

  # services
  if [[ -z "${SERVICES_RAW//[[:space:]]/}" ]]; then
    SERVICES_RAW="$(app_defaults_csv)"
    [[ -n "${SERVICES_RAW//[[:space:]]/}" ]] || die "No default services for app '$APP' (apps.yml: apps.<APP>.defaults.services)"
    log "Using default services: $SERVICES_RAW"
  fi

  parse_services "$SERVICES_RAW"

  # expand requires
  EXPANDED_SERVICES="$(expand_services)"
  log "Services: $EXPANDED_SERVICES"

  local out rid tar work
  out="$(build_release)"
  rid="${out%%|*}"
  tar="${out#*|}"; tar="${tar%%|*}"
  work="${out##*|}"

  local host
  for host in $(normalize_list "$TARGETS_RAW"); do
    deploy_one "$host" "$rid" "$tar"
  done

  rm -rf "$work"
  log "Deploy completed: $rid"
}

main "$@"