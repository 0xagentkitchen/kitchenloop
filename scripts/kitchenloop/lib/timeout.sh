#!/bin/bash
# ── Cross-platform timeout helper ──────────────────────────────────────
# Shared by kitchenloop.sh and pr-manager.sh.
#
# macOS doesn't ship GNU timeout. This helper finds gtimeout (Homebrew),
# falls back to a bash implementation that kills the entire process group
# (catches grandchildren — the key macOS fix).
#
# Returns 124 on timeout (matching GNU timeout convention).

_timeout() {
  local secs="$1"; shift

  # Try GNU timeout first (Linux, or GNU coreutils on macOS)
  if command -v timeout >/dev/null 2>&1 && timeout --version >/dev/null 2>&1; then
    timeout --signal=TERM --kill-after=10 "$secs" "$@"
    return $?
  fi

  # Try Homebrew gtimeout
  local gtimeout_path=""
  for p in /opt/homebrew/bin/gtimeout /usr/local/bin/gtimeout; do
    [ -x "$p" ] && gtimeout_path="$p" && break
  done
  if [ -n "$gtimeout_path" ]; then
    "$gtimeout_path" --signal=TERM --kill-after=10 "$secs" "$@"
    return $?
  fi

  # Bash fallback: run in a new process group, kill group on timeout
  "$@" &
  local cmd_pid=$!
  local pgid=""

  (
    sleep "$secs"
    # Get process group ID
    pgid=$(ps -o pgid= -p "$cmd_pid" 2>/dev/null | tr -d ' ')
    # SIGTERM the group first
    [ -n "$pgid" ] && kill -- -"$pgid" 2>/dev/null || kill "$cmd_pid" 2>/dev/null || true
    sleep 10
    # SIGKILL stragglers
    pgid=$(ps -o pgid= -p "$cmd_pid" 2>/dev/null | tr -d ' ')
    [ -n "$pgid" ] && kill -9 -- -"$pgid" 2>/dev/null || kill -9 "$cmd_pid" 2>/dev/null || true
  ) &
  local wdog=$!

  local exit_code=0
  wait "$cmd_pid" 2>/dev/null || exit_code=$?
  # If watchdog already fired (cmd was killed), exit_code will be 137 or 143
  kill "$wdog" 2>/dev/null || true
  wait "$wdog" 2>/dev/null 2>&1 || true

  # Check if timeout was the cause (watchdog ran to completion = cmd was killed)
  # We detect this by checking if the watchdog's sleep finished
  if [ "$exit_code" -eq 137 ] || [ "$exit_code" -eq 143 ]; then
    # Could be timeout or external signal — check if we exceeded the time
    return 124
  fi
  return $exit_code
}
