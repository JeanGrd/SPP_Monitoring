#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# common.sh
# Shared helpers for SPP Monitoring deployment scripts.
# Logs go to STDERR so functions can safely return data via STDOUT.
# ------------------------------------------------------------------------------

# Compact timestamp for IDs (e.g. 20260113_143017)
release_timestamp() {
  date +'%Y%m%d_%H%M%S'
}

# Human-readable timestamp (e.g. 2026-01-13 14:30:17)
human_timestamp() {
  date +'%Y-%m-%d %H:%M:%S'
}

# ---- Logging helpers (stderr) ------------------------------------------------

log()  { printf '[%s] %s\n'  "$(human_timestamp)" "$*" >&2; }
warn() { printf '[%s] WARN: %s\n' "$(human_timestamp)" "$*" >&2; }
err()  { printf '[%s] ERROR: %s\n' "$(human_timestamp)" "$*" >&2; }

die() {
  err "$*"
  exit 1
}

# ---- Validation helpers ------------------------------------------------------

# Converts "a,b,c" to "a b c" and trims whitespace.
normalize_list() {
  local s="${1:-}"
  s="${s//,/ }"
  s="$(echo "$s" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  echo "$s"
}

# ---- Marley functions ------------------------------------------------------

marley_query() {
  # Usage:
  #   marley_query "<app>" "<env>" "<targets>" "<os>"
  #
  # Any argument can be empty ("") to disable the filter.

  local app="${1:-}"
  local env="${2:-}"
  local targets="${3:-}"
  local os="${4:-}"

  local -a args
  args=(-F "," -H)

  [[ -n "$app"     ]] && args+=(--main_app "$app")
  [[ -n "$env"     ]] && args+=(--environment "$env")
  [[ -n "$targets" ]] && args+=(--FQDN "$targets")
  [[ -n "$os"      ]] && args+=(--os_name "$os")

  ./fake_marley "${args[@]}" "main_app,environment,fqdn,os_name"
}

# Helper to get CLI arg value or empty string
get_arg_value() {
  local key="$1"
  local val=""
  local found=0
  for ((i=0; i < ${#shift_args[@]}; i++)); do
    if [[ "${shift_args[i]}" == "$key" && $((i+1)) -lt ${#shift_args[@]} ]]; then
      val="${shift_args[i+1]}"
      found=1
      break
    fi
  done
  echo "$val"
}

get_tenant() {
  local app="$1"
  local env="$2"

  [[ -n "$app" && -n "$env" ]] || die "Cannot resolve tenant: app or env missing"

  local tenant
  tenant="$($ROOT_DIR/tools/yq -r ".apps.${app}.tenants.${env}" "$ROOT_DIR/catalogue/apps.yml")"

  [[ -n "$tenant" && "$tenant" != "null" ]] \
    || die "No tenant defined for app='$app' env='$env' in apps.yml"

  echo "$tenant"
}

remote_control() {
  # Usage: remote_control_current <tenant> <target> [control_args...]
  local tenant="$1"; shift
  local target="$1"; shift
  local base="${SPPMON_REMOTE_BASE:-SPP_Monitoring}"

  # Build a safely-quoted command line for the remote shell.
  local -a q=()
  local a
  for a in "$@"; do
    q+=("$(printf '%q' "$a")")
  done

  ssh -o StrictHostKeyChecking=no "${tenant}@${target}" \
    "cd $(printf '%q' "$base") && ./current/bin/control.sh ${q[*]}"
}