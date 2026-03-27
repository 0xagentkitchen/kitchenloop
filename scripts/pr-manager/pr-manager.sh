#!/bin/bash
# PR Manager - Autonomous PR merge automation
#
# Finds eligible PRs, runs audit/fix cycles, and merges them.
#
# Sequential (default for --pr N, or --no-parallel):
#   1. Find eligible PRs (not draft, not skipped/stuck)
#   2. Sort by merge readiness (CLEAN > BEHIND > UNSTABLE)
#   3. Spawn a claude --print session per PR with merge-pr.md prompt
#   4. Parse result, update state, loop
#
# Usage:
#   ./scripts/pr-manager/pr-manager.sh              # Continuous
#   ./scripts/pr-manager/pr-manager.sh --once        # One batch then exit
#   ./scripts/pr-manager/pr-manager.sh --pr 42       # Single PR
#   ./scripts/pr-manager/pr-manager.sh --dry-run     # Everything except merge
#   ./scripts/pr-manager/pr-manager.sh --max-prs 5   # Up to 5 PRs then exit
#   ./scripts/pr-manager/pr-manager.sh --no-parallel  # Force sequential mode

set -euo pipefail

# ── Source config if available ─────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

LIB_DIR=""
if [ -d "$SCRIPT_DIR/../kitchenloop/lib" ]; then
  LIB_DIR="$SCRIPT_DIR/../kitchenloop/lib"
elif [ -d "$SCRIPT_DIR/lib" ]; then
  LIB_DIR="$SCRIPT_DIR/lib"
fi

HAS_CONFIG=false
if [ -n "$LIB_DIR" ] && [ -f "$LIB_DIR/config.sh" ]; then
  source "$LIB_DIR/config.sh"
  if config_find 2>/dev/null; then
    config_load
    source "$LIB_DIR/tickets.sh"
    HAS_CONFIG=true
  fi
  # Cross-platform timeout with process-group kill (macOS zombie fix)
  [ -f "$LIB_DIR/timeout.sh" ] && source "$LIB_DIR/timeout.sh"
fi

# ── Base branch: env var > config > default ────────────────────────
if [ -n "${BASE_BRANCH:-}" ]; then
  : # Explicit env var takes priority
elif [ "$HAS_CONFIG" = true ]; then
  BASE_BRANCH="$(config_get_default 'repo.base_branch' 'main')"
else
  BASE_BRANCH="main"
fi

# ── Defaults ─────────────────────────────────────────────────────────
MAX_ATTEMPTS_PER_PR=3
SKIP_AFTER_FAILURES="${SKIP_AFTER_FAILURES:-1}"
PR_TIMEOUT=2700
PR_TIMEOUT_FLOOR=1800             # Minimum per-PR timeout (30 min)
BLOCKED_PR_MAX_FAILURES=2         # Fast-skip BLOCKED PRs after this many failures
POLL_INTERVAL=300
COOLDOWN_AFTER_MERGE=120
MAX_PRS=0
SPECIFIC_PR=""
ONCE=false
DRY_RUN=false
VERBOSE=0
BUDGET=0
BUDGET_START=0
CLAUDE_MAX_TURNS=80
USE_PARALLEL=false
USE_TMUX=false

# Author allowlist (empty = trust all)
AUTHOR_ALLOWLIST=""
if [ "$HAS_CONFIG" = true ]; then
  AUTHOR_ALLOWLIST=$(config_get_list "pr_manager.author_allowlist" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
  SKIP_AFTER_FAILURES=$(config_get_default "pr_manager.skip_after_failures" "1")
fi

# ── Parse arguments ──────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --once)         ONCE=true; shift ;;
    --pr)           SPECIFIC_PR="$2"; ONCE=true; USE_PARALLEL=false; shift 2 ;;
    --pr=*)         SPECIFIC_PR="${1#*=}"; ONCE=true; USE_PARALLEL=false; shift ;;
    --dry-run)      DRY_RUN=true; shift ;;
    --max-prs)      MAX_PRS="$2"; shift 2 ;;
    --max-prs=*)    MAX_PRS="${1#*=}"; shift ;;
    --timeout)      PR_TIMEOUT="$2"
                    # Enforce minimum timeout floor
                    [ "$PR_TIMEOUT" -lt "$PR_TIMEOUT_FLOOR" ] && PR_TIMEOUT="$PR_TIMEOUT_FLOOR"
                    shift 2 ;;
    --budget)       BUDGET="$2"; BUDGET_START=$(date +%s); shift 2 ;;
    --budget=*)     BUDGET="${1#*=}"; BUDGET_START=$(date +%s); shift ;;
    --max-turns)    CLAUDE_MAX_TURNS="$2"; shift 2 ;;
    --max-turns=*)  CLAUDE_MAX_TURNS="${1#*=}"; shift ;;
    --no-parallel)  USE_PARALLEL=false; USE_TMUX=false; shift ;;
    --no-tmux)      USE_TMUX=false; shift ;;
    -v|--verbose)   VERBOSE=1; shift ;;
    -vv|--debug)    VERBOSE=2; shift ;;
    --help|-h)
      echo "Usage: $0 [options]"
      echo ""
      echo "Options:"
      echo "  --once              Process one batch and exit"
      echo "  --pr <number>       Process specific PR only"
      echo "  --dry-run           Everything except actual merge"
      echo "  --max-prs <N>       Process up to N PRs then exit"
      echo "  --timeout <secs>    Per-PR timeout (default: 2700)"
      echo "  --budget <secs>     Overall time budget"
      echo "  --max-turns <N>     Max turns per Claude session (default: 80)"
      echo "  --no-parallel       Force sequential mode"
      echo "  -v, --verbose       Verbose output"
      echo "  -vv, --debug        Debug output"
      echo "  --help              Show this help"
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Setup ────────────────────────────────────────────────────────────
PROMPT_TEMPLATE="$SCRIPT_DIR/prompts/merge-pr.md"
PREP_PROMPT_TEMPLATE="$SCRIPT_DIR/prompts/prep-pr.md"
RESOLVE_PROMPT_TEMPLATE="$SCRIPT_DIR/prompts/resolve-conflicts.md"
STATE_FILE="$SCRIPT_DIR/state.json"
LOG_FILE="$SCRIPT_DIR/pr-manager.log"

# ── SIGTERM trap ─────────────────────────────────────────────────────
CHILD_PIDS=""
cleanup_on_signal() {
  local sig="$1"
  log "Received SIG${sig} -- graceful shutdown"
  for pid in $CHILD_PIDS; do
    kill "$pid" 2>/dev/null || true
  done
  sleep 2
  for pid in $CHILD_PIDS; do
    kill -9 "$pid" 2>/dev/null || true
  done
  log "PR Manager interrupted. Merged: ${MERGED_COUNT:-0}"
  exit 1
}
trap 'cleanup_on_signal TERM' TERM
trap 'cleanup_on_signal INT' INT

# ── Budget helpers ───────────────────────────────────────────────────
budget_remaining() {
  if [ "$BUDGET" -le 0 ]; then echo "999999"; return; fi
  local elapsed=$(( $(date +%s) - BUDGET_START ))
  local remaining=$(( BUDGET - elapsed ))
  [ "$remaining" -lt 0 ] && echo "0" || echo "$remaining"
}

has_budget() {
  local rem; rem=$(budget_remaining); [ "$rem" -ge 300 ]
}

if [ ! -f "$PROMPT_TEMPLATE" ]; then
  echo "ERROR: Missing prompt template: $PROMPT_TEMPLATE"
  exit 1
fi

if [ ! -f "$STATE_FILE" ]; then
  echo '{"pr_attempts": {}, "total_merged": 0, "total_stuck": 0}' > "$STATE_FILE"
fi

# ── Cross-platform timeout helper ────────────────────────────────────
# macOS doesn't ship GNU timeout. Finds gtimeout (Homebrew) or falls
# back to bash with process-group kill (catches grandchildren).
_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1 && timeout --version >/dev/null 2>&1; then
    timeout "$secs" "$@"; return $?
  fi
  local gtimeout_path=""
  for p in /opt/homebrew/bin/gtimeout /usr/local/bin/gtimeout; do
    [ -x "$p" ] && gtimeout_path="$p" && break
  done
  if [ -n "$gtimeout_path" ]; then
    "$gtimeout_path" "$secs" "$@"; return $?
  fi
  # Bash fallback: kill entire process group on timeout
  "$@" &
  local cmd_pid=$!
  ( sleep "$secs"
    kill -- -"$(ps -o pgid= -p "$cmd_pid" 2>/dev/null | tr -d ' ')" 2>/dev/null || true
    kill "$cmd_pid" 2>/dev/null || true
    sleep 5
    kill -9 -- -"$(ps -o pgid= -p "$cmd_pid" 2>/dev/null | tr -d ' ')" 2>/dev/null || true
    kill -9 "$cmd_pid" 2>/dev/null || true
  ) &
  local wdog=$!
  wait "$cmd_pid" 2>/dev/null; local exit_code=$?
  kill "$wdog" 2>/dev/null || true; wait "$wdog" 2>/dev/null 2>&1 || true
  return $exit_code
}

# ── ANSI stripping ───────────────────────────────────────────────────
strip_ansi() {
  perl -pe 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b\([AB]//g; s/\x00//g'
}

# ── Logging ──────────────────────────────────────────────────────────
log() {
  local msg="$(date '+%Y-%m-%d %H:%M:%S') | $*"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE"
}

# ── Memory management ────────────────────────────────────────────────
get_available_memory_mb() {
  if command -v vm_stat &>/dev/null; then
    local vm; vm=$(vm_stat 2>/dev/null)
    local page_size; page_size=$(echo "$vm" | awk '/page size of/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/) print $i}')
    page_size="${page_size:-16384}"
    local free inactive purgeable
    free=$(echo "$vm" | awk '/Pages free/ {gsub(/\./,"",$3); print $3}')
    inactive=$(echo "$vm" | awk '/Pages inactive/ {gsub(/\./,"",$3); print $3}')
    purgeable=$(echo "$vm" | awk '/Pages purgeable/ {gsub(/\./,"",$3); print $3}')
    echo $(( (${free:-0} + ${inactive:-0} + ${purgeable:-0}) * page_size / 1048576 ))
    return
  fi
  if [ -f /proc/meminfo ]; then
    awk '/MemAvailable:/ {print int($2/1024)}' /proc/meminfo; return
  fi
  echo 999999
}

check_memory_budget() {
  local min_mb="${1:-${PR_MANAGER_MIN_FREE_MB:-500}}"
  local avail; avail=$(get_available_memory_mb)
  [ "$avail" -ge "$min_mb" ]
}

cleanup_orphan_processes() {
  local killed=0
  for pid in $(pgrep -f 'claude.*pr-merger' 2>/dev/null || true); do
    if [ "$pid" != "$$" ] && [ "$pid" != "$PPID" ]; then
      kill "$pid" 2>/dev/null && killed=$((killed + 1)) || true
    fi
  done
  # Clean up temp files but EXCLUDE active output files (pr-merger-out-*)
  # to avoid the race condition where cleanup deletes a file mid-processing
  find /tmp -maxdepth 1 -name 'pr-merger-*' ! -name 'pr-merger-out-*' -delete 2>/dev/null || true
  rm -f /tmp/pr-prep-* 2>/dev/null || true
  [ "$killed" -gt 0 ] && log "Cleaned up $killed orphan processes" || true
}

# ── State helpers ────────────────────────────────────────────────────
get_attempts() {
  local pr_num="$1"
  jq -r --arg pr "$pr_num" '.pr_attempts[$pr].attempts // 0' "$STATE_FILE" 2>/dev/null || echo 0
}

get_last_rejected_sha() {
  local pr_num="$1"
  jq -r --arg pr "$pr_num" '.pr_attempts[$pr].rejected_sha // ""' "$STATE_FILE" 2>/dev/null || echo ""
}

update_state() {
  local pr_num="$1" result="$2"
  local ts; ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local tmp; tmp=$(mktemp)
  jq --arg pr "$pr_num" --arg res "$result" --arg ts "$ts" '
    .pr_attempts //= {} |
    .pr_attempts[$pr] //= {"attempts": 0} |
    .pr_attempts[$pr].attempts += 1 |
    .pr_attempts[$pr].last_result = $res |
    .pr_attempts[$pr].ts = $ts |
    if $res == "MERGED" then .total_merged = ((.total_merged // 0) + 1) | del(.pr_attempts[$pr].followup_ticket) else . end |
    if $res == "STUCK" then .total_stuck = ((.total_stuck // 0) + 1) else . end
  ' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

# Record the HEAD SHA when a PR is rejected (NOT_MERGEABLE/STUCK)
# so we can skip re-evaluation if no new commits have been pushed
record_rejection_sha() {
  local pr_num="$1" head_sha="$2" reason="$3"
  local tmp; tmp=$(mktemp)
  jq --arg pr "$pr_num" --arg sha "$head_sha" --arg reason "$reason" '
    .pr_attempts[$pr].rejected_sha = $sha |
    .pr_attempts[$pr].rejection_reason = $reason
  ' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

# ── Label helpers ────────────────────────────────────────────────────
add_label() { gh pr edit "$1" --add-label "$2" > /dev/null 2>&1 || true; }
remove_label() { gh pr edit "$1" --remove-label "$2" > /dev/null 2>&1 || true; }

# ── Ticket transition on merge ───────────────────────────────────────
update_tickets_on_merge() {
  local pr_num="$1"
  if [ "$HAS_CONFIG" = true ]; then
    local ticket_ids
    ticket_ids=$(ticket_extract_ids_from_pr "$pr_num")
    if [ -n "$ticket_ids" ]; then
      log "PR #$pr_num: transitioning tickets to done: $ticket_ids"
      while IFS= read -r tid; do
        [ -z "$tid" ] && continue
        ticket_transition "$tid" "done"
        ticket_add_comment "$tid" "Fixed in PR #$pr_num"
      done <<< "$ticket_ids"
    fi
  fi
}

# ── Template helper ──────────────────────────────────────────────────
template_prompt() {
  local template_file="$1" output_file="$2" pr_num="$3" pr_title="$4"
  local head_branch="$5" base_branch="$6" pr_url="$7" merge_state="$8"
  local worktree="${9:-}"
  sed \
    -e "s|{{PR_NUMBER}}|${pr_num}|g" \
    -e "s|{{PR_TITLE}}|${pr_title}|g" \
    -e "s|{{HEAD_BRANCH}}|${head_branch}|g" \
    -e "s|{{BASE_BRANCH}}|${base_branch}|g" \
    -e "s|{{PR_URL}}|${pr_url}|g" \
    -e "s|{{MERGE_STATE}}|${merge_state}|g" \
    -e "s|{{REPO_ROOT}}|${REPO_ROOT}|g" \
    -e "s|{{DRY_RUN}}|${DRY_RUN}|g" \
    -e "s|{{WORKTREE}}|${worktree}|g" \
    -e "s|{{VERIFIED_HEAD_SHA}}|${VERIFIED_HEAD_SHA:-}|g" \
    "$template_file" > "$output_file"
}

# ── PR JSON parsing ─────────────────────────────────────────────────
parse_pr_json() {
  local pr_json="$1"
  local parsed
  parsed=$(echo "$pr_json" | jq -r '[
    (.number | tostring), .title, .headRefName,
    (.baseRefName // "main"), (.mergeStateStatus // "UNKNOWN"), (.url // "N/A")
  ] | join("\u001f")')
  IFS=$'\x1f' read -r pr_num pr_title head_branch base_branch merge_state pr_url <<< "$parsed"
}

# ── Author check ─────────────────────────────────────────────────────
is_allowed_author() {
  local author="$1"
  if [ -z "$AUTHOR_ALLOWLIST" ]; then
    return 0  # Empty allowlist = trust all
  fi
  echo ",$AUTHOR_ALLOWLIST," | grep -q ",$author,"
}

# ── Find eligible PRs ───────────────────────────────────────────────
find_prs() {
  if [ -n "$SPECIFIC_PR" ]; then
    local author
    author=$(gh pr view "$SPECIFIC_PR" --json author --jq '.author.login' 2>/dev/null || echo "")
    if ! is_allowed_author "$author"; then
      log "PR #$SPECIFIC_PR is authored by '$author', not in allowlist. Skipping."
      return
    fi
    gh pr view "$SPECIFIC_PR" --json number,title,headRefName,baseRefName,mergeStateStatus,isDraft,labels,url \
      --jq '{number, title, headRefName, baseRefName, mergeStateStatus, isDraft, url, labels: [.labels[].name]}'
    return
  fi

  # Build author filter
  local author_flag=""
  if [ -n "$AUTHOR_ALLOWLIST" ]; then
    # Use the first author for the filter (gh only supports one --author)
    local first_author
    first_author=$(echo "$AUTHOR_ALLOWLIST" | cut -d',' -f1)
    author_flag="--author $first_author"
  fi

  gh pr list --state open --base "$BASE_BRANCH" $author_flag \
    --json number,title,headRefName,baseRefName,mergeStateStatus,isDraft,labels,url,author \
    --jq "
      [.[] | select(.isDraft == false) |
       select(.labels | map(.name) |
         (contains([\"pr-manager:skip\"]) or contains([\"pr-manager:stuck\"]) or contains([\"pr-manager:needs-attention\"])) | not
       )] |
      sort_by(
        (if .mergeStateStatus == \"CLEAN\" then 0
         elif .mergeStateStatus == \"BEHIND\" then 1
         elif .mergeStateStatus == \"UNSTABLE\" then 2
         else 3 end),
        (if (.title | test(\"^fix[:(]\")) then 0
         elif (.title | test(\"^improve[:(]\")) then 1
         elif (.title | test(\"^feat[:(]\")) then 2
         else 3 end),
        .number
      ) | .[] |
      {number, title, headRefName, baseRefName, mergeStateStatus, isDraft, url, labels: [.labels[].name]}
    "
}

# ── Progress monitor ────────────────────────────────────────────────
progress_monitor() {
  local outfile="$1" pr_num="$2"
  local last_stage="" dots=0
  while true; do
    sleep 15
    [ ! -f "$outfile" ] && continue
    local current_stage
    current_stage=$(grep -oE 'Stage [0-9]+:' "$outfile" 2>/dev/null | tail -1 || true)
    if [ -n "$current_stage" ] && [ "$current_stage" != "$last_stage" ]; then
      local stage_line
      stage_line=$(grep -m1 "$current_stage" "$outfile" 2>/dev/null | head -1 || true)
      [ -n "$stage_line" ] && echo "" && echo "  PR #$pr_num >> $stage_line"
      last_stage="$current_stage"; dots=0
    else
      printf "."; dots=$((dots + 1))
      [ "$dots" -ge 40 ] && echo " ($(date '+%H:%M:%S'))" && dots=0
    fi
  done
}

# ── Pre-merge deletion check ──────────────────────────────────────────
# Prevents accidental file deletions by AI agents during rebase/conflicts.
# Any file deleted by the PR must be documented in the PR description.
check_pr_deletions() {
  local pr_num="$1" head_branch="$2"
  local pr_body
  pr_body=$(gh pr view "$pr_num" --json body --jq '.body' 2>/dev/null || echo "")

  # Fail closed: if we can't fetch, block the merge
  if ! git fetch origin "$BASE_BRANCH" "$head_branch" --quiet 2>/dev/null; then
    log "PR #$pr_num: deletion check BLOCKED — git fetch failed (fail-closed)"
    return 1
  fi

  local checked_head_sha
  checked_head_sha=$(git rev-parse "origin/$head_branch" 2>/dev/null || echo "")

  local deleted_files
  deleted_files=$(git diff --name-only --diff-filter=D "origin/${BASE_BRANCH}...origin/${head_branch}" 2>/dev/null || echo "")

  if [ -z "$deleted_files" ]; then
    # TOCTOU: verify HEAD hasn't moved even on the clean path
    local current_head
    current_head=$(git rev-parse "origin/$head_branch" 2>/dev/null || echo "")
    if [ -n "$checked_head_sha" ] && [ "$checked_head_sha" != "$current_head" ]; then
      log "PR #$pr_num: BLOCKED — HEAD changed during deletion check ($checked_head_sha -> $current_head), re-fetch required"
      return 1
    fi
    VERIFIED_HEAD_SHA="$checked_head_sha"
    return 0  # No deletions, HEAD stable, safe to proceed
  fi

  local unexpected=""
  while IFS= read -r filepath; do
    [ -z "$filepath" ] && continue
    # Skip if file doesn't exist on base branch (already absent)
    if ! git cat-file -e "origin/${BASE_BRANCH}:${filepath}" 2>/dev/null; then
      continue
    fi
    # Check if deletion is documented in PR description (exact path match)
    if [ -n "$pr_body" ] && printf '%s' "$pr_body" | grep -qF "$filepath"; then
      continue
    fi
    unexpected="${unexpected}${filepath}\n"
  done <<< "$deleted_files"

  if [ -n "$unexpected" ]; then
    log "PR #$pr_num: BLOCKED — unexpected file deletions detected:"
    printf '%b' "$unexpected" | while IFS= read -r f; do
      [ -n "$f" ] && log "  - $f"
    done
    log "PR #$pr_num: To unblock, add the full repo-relative path(s) to the PR description"

    # TOCTOU: verify HEAD hasn't changed since we checked
    local current_head
    current_head=$(git rev-parse "origin/$head_branch" 2>/dev/null || echo "")
    if [ "$checked_head_sha" != "$current_head" ]; then
      log "PR #$pr_num: WARNING — HEAD changed during deletion check ($checked_head_sha -> $current_head)"
    fi

    return 1
  fi

  VERIFIED_HEAD_SHA="$checked_head_sha"
  return 0
}

# ── Security/design-blocked PR retirement ────────────────────────────
# PRs blocked by security guardrails or architecture constraints should
# not be retried — they need human intervention by design.
is_design_blocked() {
  local pr_num="$1"
  local rejection_reason
  rejection_reason=$(jq -r --arg pr "$pr_num" '.pr_attempts[$pr].rejection_reason // ""' "$STATE_FILE" 2>/dev/null || echo "")
  if [ -z "$rejection_reason" ]; then
    return 1
  fi
  # Check for security/architecture keywords in the rejection reason
  if echo "$rejection_reason" | grep -qiE 'security|auth|credential|permission|secret|breaking.change|architecture|design'; then
    return 0
  fi
  return 1
}

retire_design_blocked_pr() {
  local pr_num="$1"
  local rejection_reason
  rejection_reason=$(jq -r --arg pr "$pr_num" '.pr_attempts[$pr].rejection_reason // "design-level concern"' "$STATE_FILE" 2>/dev/null || echo "design-level concern")

  log "PR #$pr_num: retiring — blocked by design-level concern: $rejection_reason"
  gh pr comment "$pr_num" --body "$(cat <<RETIRE
## PR Retired — Design-Level Block

This PR has been retired because it is blocked by a design-level concern that cannot be resolved by automated fixes:

> $rejection_reason

The linked ticket (if any) has been moved back for rethinking. A new approach is needed.

_Retired by PR Manager_
RETIRE
)" 2>/dev/null || true
  gh pr close "$pr_num" 2>/dev/null || true
  add_label "$pr_num" "pr-manager:retired"

  # Route linked tickets back to todo with needs-rethink
  if [ "$HAS_CONFIG" = true ]; then
    local ticket_ids
    ticket_ids=$(ticket_extract_ids_from_pr "$pr_num" 2>/dev/null || echo "")
    if [ -n "$ticket_ids" ]; then
      while IFS= read -r tid; do
        [ -z "$tid" ] && continue
        ticket_transition "$tid" "todo" 2>/dev/null || true
        ticket_add_comment "$tid" "PR #$pr_num retired (design-level block: $rejection_reason). Needs a new approach." 2>/dev/null || true
      done <<< "$ticket_ids"
    fi
  fi
}

# ── BLOCKED PR fast-skip check ───────────────────────────────────────
# After N failed attempts on a BLOCKED PR with only CI failures (no human
# review changes requested), skip spawning Claude and label for human attention.
blocked_should_fast_skip() {
  local pr_num="$1" merge_state="$2" attempts="$3"
  if [ "$merge_state" != "BLOCKED" ] && [ "$merge_state" != "UNSTABLE" ]; then
    return 1  # Not blocked, don't skip
  fi
  if [ "$attempts" -lt "$BLOCKED_PR_MAX_FAILURES" ]; then
    return 1  # Haven't hit the threshold yet
  fi
  # Check if failures are CI-only (no human review changes requested)
  local review_decision
  review_decision=$(gh pr view "$pr_num" --json reviewDecision --jq '.reviewDecision' 2>/dev/null || echo "")
  if [ "$review_decision" = "CHANGES_REQUESTED" ]; then
    return 1  # Human requested changes — needs Claude to address them
  fi
  return 0  # Fast-skip: BLOCKED + enough failures + no human changes requested
}

# ── Process a single PR (sequential mode) ────────────────────────────
process_pr() {
  local pr_json="$1"
  parse_pr_json "$pr_json"

  # Memory check
  local mem_retries=0
  while ! check_memory_budget; do
    mem_retries=$((mem_retries + 1))
    if [ "$mem_retries" -ge 10 ]; then
      log "PR #$pr_num: SKIPPED - insufficient memory"; return 1
    fi
    cleanup_orphan_processes; sleep 30
  done

  local attempts; attempts=$(get_attempts "$pr_num")
  if [ "$attempts" -ge "$MAX_ATTEMPTS_PER_PR" ]; then
    log "PR #$pr_num: exceeded $MAX_ATTEMPTS_PER_PR attempts — escalating"
    add_label "$pr_num" "pr-manager:stuck"
    update_state "$pr_num" "STUCK"

    # Graduated escalation based on failure count
    if [ "$attempts" -ge 3 ]; then
      # After 3 failures: create a human-readable summary with failure history
      local failure_history
      failure_history=$(jq -r --arg pr "$pr_num" '
        .pr_attempts[$pr] | "Attempts: \(.attempts), Last result: \(.last_result // "unknown"), Last SHA: \(.rejected_sha // "unknown"), Reason: \(.rejection_reason // "unknown")"
      ' "$STATE_FILE" 2>/dev/null || echo "unknown")
      log "PR #$pr_num: 3+ failures — creating summary for human triage"
      gh pr comment "$pr_num" --body "$(cat <<ESCALATION
## PR Manager Escalation — Stuck after $attempts attempts

This PR has failed $attempts merge attempts without resolution.

**Failure history**: $failure_history

**Action needed**: Human review required. Either:
1. Fix the underlying issue and push new commits
2. Close the PR if the approach needs rethinking
3. Remove the \`pr-manager:stuck\` label to retry

_Escalated by PR Manager_
ESCALATION
)" 2>/dev/null || true
      add_label "$pr_num" "needs-attention"
    fi
    return 1
  fi
  # After 2 failures: create a follow-up ticket if one doesn't already exist
  # (runs before skip-after-failures guard so it fires even with low thresholds)
  if [ "$attempts" -ge 2 ]; then
    local has_followup
    has_followup=$(jq -r --arg pr "$pr_num" '.pr_attempts[$pr].followup_ticket // ""' "$STATE_FILE" 2>/dev/null || echo "")
    if [ -z "$has_followup" ] && [ "$HAS_CONFIG" = true ]; then
      local failure_type="retryable"
      if is_design_blocked "$pr_num"; then
        failure_type="needs_redesign"
      fi
      local rejection_reason
      rejection_reason=$(jq -r --arg pr "$pr_num" '.pr_attempts[$pr].rejection_reason // "unknown"' "$STATE_FILE" 2>/dev/null || echo "unknown")
      local pr_title
      pr_title=$(gh pr view "$pr_num" --json title --jq '.title' 2>/dev/null || echo "PR #$pr_num")

      log "PR #$pr_num: creating follow-up ticket ($failure_type) after $attempts failures"
      local followup_id=""
      followup_id=$(ticket_create \
        "Follow-up: PR #$pr_num blocked ($failure_type)" \
        "PR #$pr_num ($pr_title) has failed $attempts merge attempts.\n\n**Failure type**: $failure_type\n**Last rejection**: $rejection_reason\n\nOriginal PR: #$pr_num\n\n_Created by PR Manager escalation_" \
        2>/dev/null || echo "")

      if [ -n "$followup_id" ]; then
        # Record follow-up ticket in state to prevent duplicates
        local tmp_state
        tmp_state=$(jq --arg pr "$pr_num" --arg tid "$followup_id" \
          '.pr_attempts[$pr].followup_ticket = $tid' "$STATE_FILE" 2>/dev/null) && \
          echo "$tmp_state" > "$STATE_FILE"
        gh pr comment "$pr_num" --body "Follow-up ticket created: #$followup_id ($failure_type)" 2>/dev/null || true
        log "PR #$pr_num: follow-up ticket #$followup_id created"
      fi
    fi
  fi

  if [ "$attempts" -ge "$SKIP_AFTER_FAILURES" ]; then
    log "PR #$pr_num: $attempts prior failure(s), skipping (needs-attention)"
    add_label "$pr_num" "pr-manager:needs-attention"; return 1
  fi

  # Retire PRs blocked by security/architecture concerns after 2+ NOT_MERGEABLE attempts
  if [ "$attempts" -ge 2 ] && is_design_blocked "$pr_num"; then
    retire_design_blocked_pr "$pr_num"
    update_state "$pr_num" "STUCK"
    return 1
  fi

  # Fast-skip BLOCKED PRs that have failed too many times with only CI issues
  if blocked_should_fast_skip "$pr_num" "$merge_state" "$attempts"; then
    log "PR #$pr_num: fast-skip BLOCKED ($attempts prior failures, CI-only issues)"
    add_label "$pr_num" "pr-manager:needs-attention"
    update_state "$pr_num" "STUCK"
    return 1
  fi

  # Gate rejection memory: skip PRs that were rejected and have no new commits
  local rejected_sha
  rejected_sha=$(get_last_rejected_sha "$pr_num")
  if [ -n "$rejected_sha" ]; then
    local current_sha
    current_sha=$(gh pr view "$pr_num" --json headRefOid --jq '.headRefOid' 2>/dev/null || echo "")
    if [ "$rejected_sha" = "$current_sha" ]; then
      local prev_reason
      prev_reason=$(jq -r --arg pr "$pr_num" '.pr_attempts[$pr].rejection_reason // "unknown"' "$STATE_FILE" 2>/dev/null || echo "unknown")
      log "PR #$pr_num: skipped — previously rejected at $rejected_sha (reason: $prev_reason), no new commits"
      return 1
    fi
  fi

  add_label "$pr_num" "pr-manager:processing"
  log "Processing PR #$pr_num: $pr_title (state: $merge_state, attempt: $((attempts+1)))"

  # Pre-merge deletion check: block PRs with unexpected file deletions
  # On success, VERIFIED_HEAD_SHA is set to the pinned commit for merge
  VERIFIED_HEAD_SHA=""
  if ! check_pr_deletions "$pr_num" "$head_branch"; then
    log "PR #$pr_num: STUCK — unexpected file deletions (requires human review)"
    remove_label "$pr_num" "pr-manager:processing"
    add_label "$pr_num" "pr-manager:needs-attention"
    update_state "$pr_num" "STUCK"
    return 1
  fi

  local prompt_tmp; prompt_tmp=$(mktemp "${TMPDIR:-/tmp}/pr-merger-XXXXXX")
  template_prompt "$PROMPT_TEMPLATE" "$prompt_tmp" "$pr_num" "$pr_title" "$head_branch" "$base_branch" "$pr_url" "$merge_state"

  # Deterministic output file path per PR number (not mktemp) to avoid race
  # condition where cleanup_orphan_processes deletes the active output file
  local outfile="${TMPDIR:-/tmp}/pr-merger-out-${pr_num}"
  true > "$outfile"  # Pre-create and truncate
  local timed_out=false

  # Start progress monitor
  progress_monitor "$outfile" "$pr_num" &
  local monitor_pid=$!

  # Run claude (with fast-failure retry)
  local max_fast_retries=2
  local fast_retry=0
  local exit_code=0
  local start_ts

  while true; do
    start_ts=$(date +%s)
    cat "$prompt_tmp" | (cd "$REPO_ROOT" && claude --dangerously-skip-permissions --print \
      --max-turns "$CLAUDE_MAX_TURNS") > "$outfile" 2>&1 &
    local claude_pid=$!
    CHILD_PIDS="$CHILD_PIDS $claude_pid"

    # Watchdog: kill process group on timeout (macOS zombie fix)
    ( sleep "$PR_TIMEOUT"; touch "${outfile}.timeout"
      local pgid
      pgid=$(ps -o pgid= -p "$claude_pid" 2>/dev/null | tr -d ' ')
      [ -n "$pgid" ] && kill -- -"$pgid" 2>/dev/null || kill "$claude_pid" 2>/dev/null || true
      sleep 10
      pgid=$(ps -o pgid= -p "$claude_pid" 2>/dev/null | tr -d ' ')
      [ -n "$pgid" ] && kill -9 -- -"$pgid" 2>/dev/null || kill -9 "$claude_pid" 2>/dev/null || true
    ) &
    local watchdog=$!

    exit_code=0
    wait "$claude_pid" 2>/dev/null || exit_code=$?

    kill "$watchdog" 2>/dev/null || true; wait "$watchdog" 2>/dev/null 2>&1 || true

    # Detect fast failures: non-zero exit in <60s (init errors, permission issues)
    local elapsed=$(( $(date +%s) - start_ts ))
    if [ "$exit_code" -ne 0 ] && [ "$elapsed" -lt 60 ] && [ "$fast_retry" -lt "$max_fast_retries" ]; then
      fast_retry=$((fast_retry + 1))
      local backoff=$(( fast_retry * 10 ))
      log "PR #$pr_num: fast failure (exit $exit_code in ${elapsed}s), retry $fast_retry/$max_fast_retries in ${backoff}s"
      sleep "$backoff"
      true > "$outfile"  # Reset outfile for retry
      continue
    fi
    break
  done

  kill "$monitor_pid" 2>/dev/null || true

  if [ -f "${outfile}.timeout" ]; then
    timed_out=true; rm -f "${outfile}.timeout"
  fi

  # Parse result (strip ANSI codes before grep to avoid false negatives)
  local clean_outfile
  clean_outfile=$(mktemp "${TMPDIR:-/tmp}/pr-merger-clean-XXXXXX")
  strip_ansi < "$outfile" > "$clean_outfile" 2>/dev/null || cp "$outfile" "$clean_outfile"

  # Post-run assertion: if outfile is 0 bytes and process exited 0, something is wrong
  if [ ! -s "$clean_outfile" ] && [ "$exit_code" -eq 0 ]; then
    log "PR #$pr_num: ERROR — outfile is 0 bytes despite exit code 0 (agent failed to produce output)"
  fi

  # Extract RESULT regardless of exit code — a SIGTERMed process (exit 143)
  # may have already written RESULT: MERGED before being killed
  local result="UNKNOWN"
  local last_bytes=""
  last_bytes=$(tail -c 500 "$clean_outfile" 2>/dev/null || true)

  # Anchored RESULT greps to avoid matching mid-string in log messages
  if printf '%s\n' "$last_bytes" | grep -qE '^RESULT: MERGED' 2>/dev/null; then
    result="MERGED"
  elif grep -qE '^RESULT: MERGED' "$clean_outfile" 2>/dev/null; then
    result="MERGED"
  elif printf '%s\n' "$last_bytes" | grep -qE '^RESULT: PREPPED' 2>/dev/null; then
    result="PREPPED"
  elif grep -qE '^RESULT: PREPPED' "$clean_outfile" 2>/dev/null; then
    result="PREPPED"
  elif printf '%s\n' "$last_bytes" | grep -qE '^RESULT: STUCK' 2>/dev/null; then
    result="STUCK"
  elif grep -qE '^RESULT: STUCK' "$clean_outfile" 2>/dev/null; then
    result="STUCK"
  elif printf '%s\n' "$last_bytes" | grep -qE '^RESULT: NOT_MERGEABLE' 2>/dev/null; then
    result="NOT_MERGEABLE"
  elif grep -qE '^RESULT: NOT_MERGEABLE' "$clean_outfile" 2>/dev/null; then
    result="NOT_MERGEABLE"
  fi

  # If no RESULT line found, apply fallback logic
  if [ "$result" = "UNKNOWN" ]; then
    if [ "$timed_out" = true ]; then
      result="TIMEOUT"
    elif [ "$exit_code" -ne 0 ]; then
      result="FAILED"
    fi
  fi

  # GitHub API fallback: if RESULT is still UNKNOWN or FAILED, check if the PR
  # was actually merged on GitHub (handles cases where output was truncated)
  if [ "$result" = "UNKNOWN" ] || [ "$result" = "FAILED" ] || [ "$result" = "TIMEOUT" ]; then
    local gh_state
    gh_state=$(gh pr view "$pr_num" --json state,mergedAt --jq '.state' 2>/dev/null || echo "")
    if [ "$gh_state" = "MERGED" ]; then
      log "PR #$pr_num: GitHub API confirms MERGED (overriding result=$result)"
      result="MERGED"
    fi
  fi

  # Log discrepancy between exit code and RESULT line
  if [ "$exit_code" -ne 0 ] && [ "$result" = "MERGED" ]; then
    log "PR #$pr_num: NOTE — exit code $exit_code but RESULT=MERGED (honouring merge)"
  fi

  rm -f "$clean_outfile"

  log "PR #$pr_num: Result=$result (exit=$exit_code)"
  update_state "$pr_num" "$result"

  # C8: Reset attempt count on CLEAN merge state (PR is in good shape)
  if [ "$merge_state" = "CLEAN" ]; then
    local tmp_reset; tmp_reset=$(mktemp)
    jq --arg pr "$pr_num" '
      .pr_attempts[$pr].attempts = 0
    ' "$STATE_FILE" > "$tmp_reset" 2>/dev/null && mv "$tmp_reset" "$STATE_FILE" || rm -f "$tmp_reset"
  fi

  case "$result" in
    MERGED)
      remove_label "$pr_num" "pr-manager:processing"
      update_tickets_on_merge "$pr_num"
      # C8: Reset attempt count and clear rejection memory on successful merge
      local tmp_reset; tmp_reset=$(mktemp)
      jq --arg pr "$pr_num" '
        .pr_attempts[$pr].attempts = 0 |
        .pr_attempts[$pr].rejected_sha = null |
        .pr_attempts[$pr].rejection_reason = null
      ' "$STATE_FILE" > "$tmp_reset" 2>/dev/null && mv "$tmp_reset" "$STATE_FILE" || rm -f "$tmp_reset"
      MERGED_COUNT=$((MERGED_COUNT + 1))
      sleep "$COOLDOWN_AFTER_MERGE"
      ;;
    PREPPED)
      remove_label "$pr_num" "pr-manager:processing"
      ;;
    STUCK|NOT_MERGEABLE)
      remove_label "$pr_num" "pr-manager:processing"
      add_label "$pr_num" "pr-manager:needs-attention"
      # Record rejection SHA for gate memory — skip re-evaluation until new commits
      local current_head_sha
      current_head_sha=$(gh pr view "$pr_num" --json headRefOid --jq '.headRefOid' 2>/dev/null || echo "")
      if [ -n "$current_head_sha" ]; then
        record_rejection_sha "$pr_num" "$current_head_sha" "$result"
      fi
      ;;
    *)
      remove_label "$pr_num" "pr-manager:processing"
      ;;
  esac

  rm -f "$prompt_tmp" "$outfile"
  return 0
}

# ── Main loop ────────────────────────────────────────────────────────
cleanup_orphan_processes
MERGED_COUNT=0
PROCESSED_COUNT=0

log "PR Manager started (base=$BASE_BRANCH, max_prs=$MAX_PRS, once=$ONCE, budget=$BUDGET)"

while true; do
  if ! has_budget; then
    log "Budget exhausted. Merged: $MERGED_COUNT, Processed: $PROCESSED_COUNT"
    break
  fi

  pr_list=$(find_prs 2>/dev/null)

  if [ -z "$pr_list" ]; then
    if [ "$ONCE" = true ]; then
      log "No eligible PRs found. Exiting."
      break
    fi
    log "No eligible PRs. Sleeping ${POLL_INTERVAL}s..."
    sleep "$POLL_INTERVAL"
    continue
  fi

  while IFS= read -r pr_json; do
    [ -z "$pr_json" ] && continue

    if [ "$MAX_PRS" -gt 0 ] && [ "$PROCESSED_COUNT" -ge "$MAX_PRS" ]; then
      log "Reached max PRs ($MAX_PRS). Stopping."
      break 2
    fi

    if ! has_budget; then
      log "Budget exhausted during batch."
      break 2
    fi

    process_pr "$pr_json" || true
    PROCESSED_COUNT=$((PROCESSED_COUNT + 1))

  done <<< "$pr_list"

  if [ "$ONCE" = true ]; then
    break
  fi

  log "Batch complete. Merged: $MERGED_COUNT. Sleeping ${POLL_INTERVAL}s..."
  sleep "$POLL_INTERVAL"
done

log "PR Manager finished. Merged: $MERGED_COUNT, Processed: $PROCESSED_COUNT"
