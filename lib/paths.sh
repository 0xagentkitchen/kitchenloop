#!/bin/bash
# paths.sh — Repo contract: artifact path resolution
#
# All artifact locations are read from kitchenloop.yaml paths: section.
# The orchestrator calls these functions instead of hardcoding paths.
#
# Usage:
#   source lib/config.sh && config_load
#   source lib/paths.sh
#   report_dir=$(path_reports)
#   loop_state=$(path_loop_state)

# Guard against double-sourcing
[[ -n "${_KITCHENLOOP_PATHS_LOADED:-}" ]] && return 0
_KITCHENLOOP_PATHS_LOADED=1

# Requires config.sh to be loaded first
if [ -z "${_KITCHENLOOP_CONFIG_LOADED:-}" ]; then
  echo "ERROR: paths.sh requires config.sh to be loaded first"
  exit 1
fi

# ─── Path functions ─────────────────────────────────────────────────────
# Each function reads from config, creates the directory if needed, and
# returns the absolute path (relative to KITCHENLOOP_ROOT).

_resolve_path() {
  local config_key="$1"
  local default="$2"
  local val
  val=$(config_get_default "paths.$config_key" "$default")
  # Make absolute relative to repo root
  if [[ "$val" != /* ]]; then
    val="${KITCHENLOOP_ROOT}/$val"
  fi
  echo "$val"
}

_resolve_dir() {
  local path
  path=$(_resolve_path "$1" "$2")
  mkdir -p "$path"
  echo "$path"
}

# path_reports — directory for experience reports and loop reviews
path_reports() {
  _resolve_dir "reports" "docs/internal/reports"
}

# path_loop_state — path to the loop state file
path_loop_state() {
  local path
  path=$(_resolve_path "loop_state" "docs/internal/loop-state.md")
  mkdir -p "$(dirname "$path")"
  echo "$path"
}

# path_patterns — path to the codebase patterns file
path_patterns() {
  local path
  path=$(_resolve_path "patterns" "memory/codebase-patterns.md")
  mkdir -p "$(dirname "$path")"
  echo "$path"
}

# path_logs — directory for phase logs
path_logs() {
  _resolve_dir "logs" ".kitchenloop/logs"
}

# path_scenarios — directory where ideate writes its output
path_scenarios() {
  _resolve_dir "scenarios" "scenarios/incubating"
}

# path_worktree_prefix — base directory for worktrees
path_worktree_prefix() {
  _resolve_dir "worktree_prefix" ".claude/worktrees"
}

# path_execute_worktree — persistent worktree for execute phase
path_execute_worktree() {
  _resolve_path "execute_worktree" ".claude/worktrees/kitchenloop"
}

# path_iteration_worktree N — worktree path for iteration N
path_iteration_worktree() {
  local iter_num="$1"
  echo "$(path_worktree_prefix)/kitchen-iter-${iter_num}"
}

# path_quality_bar — path to quality bar file
path_quality_bar() {
  local path
  path=$(_resolve_path "quality_bar" ".kitchenloop/quality-bar.md")
  mkdir -p "$(dirname "$path")"
  echo "$path"
}

# path_uat_runs — directory for UAT evaluation evidence
path_uat_runs() {
  _resolve_dir "uat_runs" ".kitchenloop/uat-runs"
}

# path_uat_cards — directory for sealed UAT test cards
path_uat_cards() {
  _resolve_dir "uat_cards" ".kitchenloop/uat-cards"
}

# path_unbeatable_tests — project-specific L3/L4 test guidance
path_unbeatable_tests() {
  local path
  path=$(_resolve_path "unbeatable_tests" ".kitchenloop/unbeatable-tests.md")
  mkdir -p "$(dirname "$path")"
  echo "$path"
}

# path_metrics — iteration metrics file for drift tracking
path_metrics() {
  local path
  path=$(_resolve_path "metrics" ".kitchenloop/metrics.json")
  mkdir -p "$(dirname "$path")"
  echo "$path"
}

# path_coverage_matrix — spec surface coverage tracking
path_coverage_matrix() {
  local path
  path=$(_resolve_path "coverage_matrix" ".kitchenloop/coverage-matrix.yaml")
  mkdir -p "$(dirname "$path")"
  echo "$path"
}

# path_blocked_combos — structured blocked combos registry
path_blocked_combos() {
  local path
  path=$(_resolve_path "blocked_combos" ".kitchenloop/blocked-combos.yaml")
  mkdir -p "$(dirname "$path")"
  echo "$path"
}

# path_ui_test_state — path to the UI test state file
path_ui_test_state() {
  local path
  path=$(_resolve_path "ui_test_state" ".kitchenloop/ui-test-state.json")
  mkdir -p "$(dirname "$path")"
  echo "$path"
}

# path_ui_test_runs — directory for UI test run evidence
path_ui_test_runs() {
  _resolve_dir "ui_test_runs" ".kitchenloop/ui-test-runs"
}

# path_ui_test_screenshots — directory for UI test screenshots (from ui_tests.screenshot_dir config)
path_ui_test_screenshots() {
  local dir
  dir=$(config_get_default "ui_tests.screenshot_dir" ".kitchenloop/ui-test-screenshots")
  if [[ "$dir" != /* ]]; then
    dir="${KITCHENLOOP_ROOT}/$dir"
  fi
  mkdir -p "$dir"
  echo "$dir"
}
