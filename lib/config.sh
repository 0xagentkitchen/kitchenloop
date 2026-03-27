#!/bin/bash
# config.sh — YAML config loader for KitchenLoop
#
# Reads kitchenloop.yaml using yq. All orchestrator scripts source this file.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
#   config_load                                # Must be called first
#   config_get "project.name"                  # Get a scalar value
#   config_get_list "spec.dimensions.features" # Get list items (newline-separated)
#   config_require "project.name" "Project name" # Exit if key missing

# Guard against double-sourcing
[[ -n "${_KITCHENLOOP_CONFIG_LOADED:-}" ]] && return 0
_KITCHENLOOP_CONFIG_LOADED=1

# ─── Config file resolution ─────────────────────────────────────────────
# Search order: $KITCHENLOOP_CONFIG > ./kitchenloop.yaml > repo root
_config_file=""

_find_config() {
  if [ -n "${KITCHENLOOP_CONFIG:-}" ] && [ -f "$KITCHENLOOP_CONFIG" ]; then
    _config_file="$KITCHENLOOP_CONFIG"
    return 0
  fi
  # Walk up from CWD to find kitchenloop.yaml
  local dir="$PWD"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/kitchenloop.yaml" ]; then
      _config_file="$dir/kitchenloop.yaml"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

# ─── Dependency check ───────────────────────────────────────────────────
_check_yq() {
  if ! command -v yq &>/dev/null; then
    echo "ERROR: yq is required but not installed."
    echo "  Install: brew install yq  (macOS)"
    echo "           go install github.com/mikefarah/yq/v4@latest  (Go)"
    echo "           snap install yq  (Linux)"
    exit 1
  fi
}

# ─── Public API ─────────────────────────────────────────────────────────

# config_load — validate config file exists and is parseable
config_load() {
  _check_yq
  if ! _find_config; then
    echo "ERROR: kitchenloop.yaml not found."
    echo "  Run: kitchenloop init  (to create one)"
    echo "  Or set KITCHENLOOP_CONFIG=/path/to/kitchenloop.yaml"
    exit 1
  fi
  # Validate YAML is parseable
  if ! yq '.' "$_config_file" >/dev/null 2>&1; then
    echo "ERROR: kitchenloop.yaml is not valid YAML: $_config_file"
    exit 1
  fi
  export KITCHENLOOP_CONFIG="$_config_file"
  local root
  root="$(dirname "$_config_file")"
  export KITCHENLOOP_ROOT="$root"
}

# config_get "path.to.key" — return scalar value (empty string if not found)
# NOTE: uses yq without the // alternative operator because // treats YAML
# boolean false as falsy and returns the alternative instead of "false".
config_get() {
  local key="$1"
  local val
  val=$(yq ".$key" "$_config_file" 2>/dev/null)
  # yq returns "null" for missing keys
  if [ -z "$val" ] || [ "$val" = "null" ]; then
    echo ""
  else
    echo "$val"
  fi
}

# config_get_list "path.to.list" — return list items, one per line
config_get_list() {
  local key="$1"
  # shellcheck disable=SC1087
  yq ".$key[]" "$_config_file" 2>/dev/null || true
}

# config_get_default "path.to.key" "default_value" — return value or default
config_get_default() {
  local key="$1"
  local default="$2"
  local val
  val=$(config_get "$key")
  if [ -z "$val" ]; then
    echo "$default"
  else
    echo "$val"
  fi
}

# config_require "path.to.key" "description" — exit if key is missing or empty
config_require() {
  local key="$1"
  local desc="${2:-$key}"
  local val
  val=$(config_get "$key")
  if [ -z "$val" ]; then
    echo "ERROR: Required config key '$key' ($desc) is missing or empty in $_config_file"
    exit 1
  fi
  echo "$val"
}

# config_has "path.to.key" — return 0 if key exists and is non-empty
config_has() {
  local key="$1"
  local val
  val=$(config_get "$key")
  [ -n "$val" ]
}

# config_find — check if a config file can be found (public wrapper for _find_config)
config_find() {
  _find_config
}

# config_file — return path to the loaded config file
config_file() {
  echo "$_config_file"
}
