#!/usr/bin/env bash

export SPPMON_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SPPMON_RELEASE_DIR="$(cd "$SPPMON_SCRIPT_DIR/.." && pwd)"

# BASE_DIR = parent of releases/ directory
# Release dir is: <base>/releases/<release_id>
export SPPMON_BASE_DIR="$(cd "$SPPMON_RELEASE_DIR/.." && pwd)"

# Paths (relative to release root unless absolute)
export SPPMON_ETC_DIR="$SPPMON_RELEASE_DIR/etc"
export SPPMON_LIB_DIR="$SPPMON_RELEASE_DIR/lib"

export SPPMON_VOLUMES="$SPPMON_BASE_DIR/volumes"
export SPPMON_DATA_DIR="$SPPMON_VOLUMES/data"
export SPPMON_LOG_DIR="$SPPMON_VOLUMES/logs"
export SPPMON_RUN_DIR="$SPPMON_VOLUMES/run"
