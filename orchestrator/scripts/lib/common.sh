#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# common.sh
# Shared helpers for SPP Monitoring deployment scripts.
# Logs go to STDERR so functions can safely return data via STDOUT.
# ------------------------------------------------------------------------------

# ---- Time helpers ------------------------------------------------------------

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

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

# Converts "a,b,c" to "a b c" and trims whitespace.
normalize_list() {
  local s="${1:-}"
  s="${s//,/ }"
  s="$(echo "$s" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  echo "$s"
}

# Valid app/env names: letters, digits, underscore, dash.
is_valid_name() {
  [[ "${1:-}" =~ ^[A-Za-z0-9_-]+$ ]]
}