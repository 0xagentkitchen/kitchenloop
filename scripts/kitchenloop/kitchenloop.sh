#!/bin/bash
# Kitchen Loop — the Loop that Cooks! — Autonomous improvement loop
#
# Runs all phases of the Kitchen Loop in sequence, then loops:
#   Phase 1: Ideate   - Brainstorm & implement a usage scenario, test it
#   Phase 2: Triage   - Extract findings into tickets
#   Phase 3: Execute  - Pick top tickets, implement, create PRs
#   Phase 3.5: Polish - Run pr-manager to harden and merge open PRs
#   Phase 4: Regress  - Full regression, update loop state, iteration summary
#
# Each iteration runs in an isolated git worktree (kitchen/iter-N branch).
# Backlog grooming runs before the first loop and every N iterations thereafter.
# Auto-review runs every N iterations (configurable).
#
# Usage:
#   ./scripts/kitchenloop/kitchenloop.sh 5                    # 5 full loops (strategy mode)
#   ./scripts/kitchenloop/kitchenloop.sh 3 --mode backtest    # 3 loops in backtest mode
#   ./scripts/kitchenloop/kitchenloop.sh 3 --mode exploration # 3 loops in exploration mode
#   ./scripts/kitchenloop/kitchenloop.sh 20 --mode user-only  # 20 rapid ideation loops (fill backlog)
#   ./scripts/kitchenloop/kitchenloop.sh 10 --mode dev-only   # 10 implementation loops (drain backlog)
#   ./scripts/kitchenloop/kitchenloop.sh 3 --skip ideate      # Skip ideate (already have tickets)
#   ./scripts/kitchenloop/kitchenloop.sh 5 --skip ideate,triage  # Jump straight to execute
#   ./scripts/kitchenloop/kitchenloop.sh 1 --only execute     # Run only execute phase
#   ./scripts/kitchenloop/kitchenloop.sh 1 --only polish      # Run only polish phase
#   ./scripts/kitchenloop/kitchenloop.sh 5 --no-backlog       # Skip backlog grooming
#   ./scripts/kitchenloop/kitchenloop.sh 5 --skip polish      # Skip PR hardening
#   ./scripts/kitchenloop/kitchenloop.sh 5 --review-interval 3  # Auto-review every 3 iters
#   ./scripts/kitchenloop/kitchenloop.sh 5 --aggressive-polish   # Process up to 4 PRs/iter
#   ./scripts/kitchenloop/kitchenloop.sh 5 --polish-max-prs 3   # Process up to 3 PRs/iter

KITCHENLOOP_VERSION="v1.0.0"

set -euo pipefail

# ─── Single-instance lock (mkdir-based, works on macOS + Linux) ──────
LOCK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.kitchenloop/kitchenloop.lock"
mkdir -p "$(dirname "$LOCK_DIR")"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  if [ -f "$LOCK_DIR/pid" ]; then
    OLD_PID=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
      echo "ERROR: Another kitchenloop instance is already running (pid $OLD_PID, lock: $LOCK_DIR)"
      exit 1
    fi
    echo "  Removing stale lock (pid $OLD_PID no longer running)"
    rm -rf "$LOCK_DIR"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
      echo "ERROR: Another instance grabbed the lock during stale recovery"
      exit 1
    fi
  else
    rm -rf "$LOCK_DIR"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
      echo "ERROR: Another instance grabbed the lock during recovery"
      exit 1
    fi
  fi
fi
echo $$ > "$LOCK_DIR/pid"

# ─── Cleanup on exit ────────────────────────────────────────────────
cleanup() {
  for pid in ${CHILD_PIDS[@]+"${CHILD_PIDS[@]}"}; do
    pkill -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
  done
  jobs -p | xargs kill 2>/dev/null || true
  rm -rf "$LOCK_DIR"
  if [ -n "${ITER_WORKTREE:-}" ] && [ -d "$ITER_WORKTREE" ]; then
    echo ""
    echo "  [cleanup] Worktree preserved: $ITER_WORKTREE"
    echo "  [cleanup] Remove with: git worktree remove $ITER_WORKTREE"
  fi
}
CHILD_PIDS=()
trap cleanup EXIT INT TERM

remove_pid() {
  local target="$1"
  local new=()
  for p in ${CHILD_PIDS[@]+"${CHILD_PIDS[@]}"}; do
    [[ "$p" != "$target" ]] && new+=("$p")
  done
  CHILD_PIDS=(${new[@]+"${new[@]}"})
}

# ─── Resolve script and repo root ───────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source lib layer (look for lib/ relative to script, or in parent)
LIB_DIR=""
if [ -d "$SCRIPT_DIR/lib" ]; then
  LIB_DIR="$SCRIPT_DIR/lib"
elif [ -d "$SCRIPT_DIR/../lib" ]; then
  LIB_DIR="$SCRIPT_DIR/../lib"
fi

if [ -n "$LIB_DIR" ] && [ -f "$LIB_DIR/config.sh" ]; then
  source "$LIB_DIR/config.sh"
  config_load
  source "$LIB_DIR/paths.sh"
  source "$LIB_DIR/tickets.sh"
  # Cross-platform timeout with process-group kill (macOS zombie fix)
  [ -f "$LIB_DIR/timeout.sh" ] && source "$LIB_DIR/timeout.sh"
  REPO_ROOT="$KITCHENLOOP_ROOT"
  HAS_CONFIG=true
else
  # Fallback: no config, use sensible defaults
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
  HAS_CONFIG=false
  # Cross-platform timeout (try script-adjacent lib first, then SCRIPT_DIR/lib)
  for _tpath in "$SCRIPT_DIR/lib/timeout.sh" "$SCRIPT_DIR/../lib/timeout.sh"; do
    [ -f "$_tpath" ] && source "$_tpath" && break
  done
fi

PROMPTS_DIR="$SCRIPT_DIR/prompts"

# ─── Config-driven defaults ──────────────────────────────────────────
if [ "$HAS_CONFIG" = true ]; then
  BASE_BRANCH=$(config_get_default "repo.base_branch" "main")
  ITER_BRANCH_PREFIX=$(config_get_default "repo.iteration_branch_prefix" "kitchen/iter")
  ENV_FILE=$(config_get_default "repo.env_file" ".env")
  FULL_TEST_CMD=$(config_get_default "verification.oracle.full_command" "make test")
  QUICK_TEST_CMD=$(config_get_default "verification.oracle.quick_command" "make test")
  LINT_CMD=$(config_get_default "verification.oracle.lint_command" "make lint")
  SECURITY_CMD=$(config_get_default "verification.oracle.security_command" "")
  SMOKE_CMD=$(config_get_default "verification.oracle.smoke_command" "")
  CANARY_CHECK_CMD=$(config_get_default "verification.oracle.canary_check_command" "")
  PASS_RATE_FLOOR=$(config_get_default "verification.stop_conditions.pass_rate_floor" "0.95")
  MAX_CONSEC_FAIL_CFG=$(config_get_default "verification.stop_conditions.max_consecutive_failures" "3")
  TEST_COUNT_DECLINE_ITERS=$(config_get_default "verification.stop_conditions.test_count_decline_iters" "3")
  LOGS_DIR=$(path_logs)
else
  BASE_BRANCH="main"
  ITER_BRANCH_PREFIX="kitchen/iter"
  ENV_FILE=".env"
  FULL_TEST_CMD="make test"
  QUICK_TEST_CMD="make test"
  LINT_CMD="make lint"
  SECURITY_CMD=""
  SMOKE_CMD=""
  CANARY_CHECK_CMD=""
  PASS_RATE_FLOOR="0.95"
  MAX_CONSEC_FAIL_CFG="3"
  TEST_COUNT_DECLINE_ITERS="3"
  LOGS_DIR="$REPO_ROOT/.kitchenloop/logs"
fi

mkdir -p "$LOGS_DIR"
LOG_FILE="$LOGS_DIR/kitchenloop.log"

# ─── Source .env file ────────────────────────────────────────────────────
if [ -f "$REPO_ROOT/$ENV_FILE" ]; then
  echo "Pre-flight: Sourcing $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  source "$REPO_ROOT/$ENV_FILE"
  set +a
fi

# ─── Defaults ─────────────────────────────────────────────────────────
MAX_LOOPS=5
MAX_CONSECUTIVE_FAILS="${MAX_CONSEC_FAIL_CFG}"
MODE="strategy"
REGRESS_QUICK=false

if [ "$HAS_CONFIG" = true ]; then
  BACKLOG_INTERVAL=$(config_get_default "runtime.backlog_interval" "3")
  REVIEW_INTERVAL=$(config_get_default "runtime.review_interval" "3")
  POLISH_MAX_PRS=$(config_get_default "runtime.polish_max_prs" "2")
  IDEATE_TIMEOUT=$(config_get_default "runtime.timeouts.ideate" "2700")
  TRIAGE_TIMEOUT=$(config_get_default "runtime.timeouts.triage" "1200")
  EXECUTE_TIMEOUT=$(config_get_default "runtime.timeouts.execute" "3600")
  POLISH_TIMEOUT=$(config_get_default "runtime.timeouts.polish" "5400")
  REGRESS_TIMEOUT=$(config_get_default "runtime.timeouts.regress" "9000")
  BACKLOG_TIMEOUT=$(config_get_default "runtime.timeouts.backlog" "900")
  MAX_NO_WORK_LOOPS=$(config_get_default "runtime.max_no_work_loops" "3")
  MAX_DRAIN_ENTRIES=$(config_get_default "runtime.max_drain_entries" "3")
  FORCE_IDEATE_INTERVAL=$(config_get_default "runtime.force_ideate_interval" "10")
  TICKET_DROUGHT_THRESHOLD=$(config_get_default "runtime.ticket_drought_threshold" "5")
  STARVE_BACKLOG_THRESHOLD=$(config_get_default "runtime.starve_backlog_threshold" "3")
  STARVE_SKIP_EXECUTE_THRESHOLD=$(config_get_default "runtime.starve_skip_execute_threshold" "6")
  STATE_DIR=$(config_get_default "runtime.state_dir" ".kitchenloop/state")
  # Model routing (per-phase, optional)
  IDEATE_MODEL=$(config_get_default "models.ideate" "")
  TRIAGE_MODEL=$(config_get_default "models.triage" "")
  EXECUTE_MODEL=$(config_get_default "models.execute" "")
  POLISH_MODEL=$(config_get_default "models.polish" "")
  REGRESS_MODEL=$(config_get_default "models.regress" "")
  BACKLOG_MODEL=$(config_get_default "models.backlog" "")
  REVIEW_MODEL=$(config_get_default "models.review" "")
else
  BACKLOG_INTERVAL=3
  REVIEW_INTERVAL=3
  POLISH_MAX_PRS=2
  IDEATE_TIMEOUT=2700
  TRIAGE_TIMEOUT=1200
  EXECUTE_TIMEOUT=3600
  POLISH_TIMEOUT=5400
  REGRESS_TIMEOUT=9000
  BACKLOG_TIMEOUT=900
  MAX_NO_WORK_LOOPS=3
  MAX_DRAIN_ENTRIES=3
  FORCE_IDEATE_INTERVAL=10
  TICKET_DROUGHT_THRESHOLD=5
  STARVE_BACKLOG_THRESHOLD=3
  STARVE_SKIP_EXECUTE_THRESHOLD=6
  STATE_DIR=".kitchenloop/state"
  IDEATE_MODEL=""
  TRIAGE_MODEL=""
  EXECUTE_MODEL=""
  POLISH_MODEL=""
  REGRESS_MODEL=""
  BACKLOG_MODEL=""
  REVIEW_MODEL=""
fi

# ── Persistent counter helpers ─────────────────────────────────────────
# Persist counters to STATE_DIR so they survive process restarts.
PERSISTENT_STATE_DIR="$REPO_ROOT/$STATE_DIR"
mkdir -p "$PERSISTENT_STATE_DIR"

persist_counter() {
  local name="$1" value="$2"
  echo "$value" > "$PERSISTENT_STATE_DIR/${name}.counter"
}

load_counter() {
  local name="$1" default="${2:-0}"
  local file="$PERSISTENT_STATE_DIR/${name}.counter"
  if [ -f "$file" ]; then
    cat "$file" 2>/dev/null || echo "$default"
  else
    echo "$default"
  fi
}

AGGRESSIVE_POLISH=false
AGGRESSIVE_POLISH_MAX_PRS=4

# Drain mode: auto-trigger when PR backpressure is too high
DRAIN_THRESHOLD=25        # Enter drain mode when open PRs exceed this
DRAIN_EXIT_THRESHOLD=5    # Exit drain mode when open PRs drop below this
DRAIN_MODE=false
MAX_DRAIN_ZERO_MERGES=2   # Exit drain mode after N consecutive loops that merge 0 PRs
DRAIN_ZERO_MERGE_COUNT=0

SKIP_PHASES=""
ONLY_PHASE=""
NO_BACKLOG=false
BACKLOG_INTERVAL_EXPLICIT=false
REVIEW_INTERVAL_EXPLICIT=false
FORCE_WORK=false

require_int() {
  [[ "$1" =~ ^[0-9]+$ ]] || { echo "ERROR: $2 must be a positive integer, got '$1'"; exit 1; }
}

# ─── Parse arguments ─────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --skip)        SKIP_PHASES="$2"; shift 2 ;;
    --skip=*)      SKIP_PHASES="${1#*=}"; shift ;;
    --only)        ONLY_PHASE="$2"; shift 2 ;;
    --only=*)      ONLY_PHASE="${1#*=}"; shift ;;
    --no-backlog)  NO_BACKLOG=true; shift ;;
    --backlog-interval)
      require_int "$2" "--backlog-interval"
      BACKLOG_INTERVAL="$2"; BACKLOG_INTERVAL_EXPLICIT=true; shift 2 ;;
    --ideate-timeout)   require_int "$2" "--ideate-timeout"; IDEATE_TIMEOUT="$2"; shift 2 ;;
    --execute-timeout)  require_int "$2" "--execute-timeout"; EXECUTE_TIMEOUT="$2"; shift 2 ;;
    --polish-timeout)   require_int "$2" "--polish-timeout"; POLISH_TIMEOUT="$2"; shift 2 ;;
    --triage-timeout)   require_int "$2" "--triage-timeout"; TRIAGE_TIMEOUT="$2"; shift 2 ;;
    --regress-timeout)  require_int "$2" "--regress-timeout"; REGRESS_TIMEOUT="$2"; shift 2 ;;
    --mode)
      MODE="$2"
      case "$MODE" in
        strategy|backtest|exploration|user-only|dev-only|ui) ;;
        *) echo "ERROR: --mode must be 'strategy', 'backtest', 'exploration', 'user-only', 'dev-only', or 'ui', got '$MODE'"; exit 1 ;;
      esac
      shift 2 ;;
    --mode=*)
      MODE="${1#*=}"
      case "$MODE" in
        strategy|backtest|exploration|user-only|dev-only|ui) ;;
        *) echo "ERROR: --mode must be 'strategy', 'backtest', 'exploration', 'user-only', 'dev-only', or 'ui', got '$MODE'"; exit 1 ;;
      esac
      shift ;;
    --review-interval)
      require_int "$2" "--review-interval"
      REVIEW_INTERVAL="$2"; REVIEW_INTERVAL_EXPLICIT=true; shift 2 ;;
    --base)              BASE_BRANCH="$2"; shift 2 ;;
    --base=*)            BASE_BRANCH="${1#*=}"; shift ;;
    --aggressive-polish) AGGRESSIVE_POLISH=true; shift ;;
    --regress-quick)     REGRESS_QUICK=true; shift ;;
    --regress-full)      REGRESS_QUICK=false; shift ;;
    --force-work)        FORCE_WORK=true; shift ;;
    --polish-max-prs)    require_int "$2" "--polish-max-prs"; POLISH_MAX_PRS="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $0 [loops] [options]"
      echo ""
      echo "Options:"
      echo "  --base <branch>        Target branch for worktrees, PRs, and merges (default: main, env: BASE_BRANCH)"
      echo "  --mode <mode>          Loop mode: strategy (default), backtest, exploration, user-only, dev-only, ui"
      echo "                           user-only: rapid ideation+triage loop (fills the backlog fast)"
      echo "                           dev-only:  implementation only (works off existing backlog)"
      echo "                           ui:        UI-driven loop, one browser flow per iteration"
      echo "  --skip <phases>        Comma-separated phases to skip (ideate,triage,execute,polish,regress)"
      echo "  --only <phase>         Run only this phase each loop"
      echo "  --no-backlog           Skip backlog grooming entirely"
      echo "  --backlog-interval N   Run backlog grooming every N loops (default: 3)"
      echo "  --review-interval N    Run auto-review every N iterations (default: 3, 0 = never)"
      echo "  --aggressive-polish    Process up to 4 PRs per iteration (default: 2)"
      echo "  --polish-max-prs N     Max PRs to process per iteration (default: 2)"
      echo "  --regress-quick        Quick regress: skip full suite, run smoke test only"
      echo "  --regress-full         Force full regress (override --regress-quick)"
      echo "  --force-work           Skip backpressure checks, always run execute"
      echo "  --ideate-timeout N     Ideate phase timeout in seconds (default: 2700)"
      echo "  --triage-timeout N     Triage phase timeout in seconds (default: 1200)"
      echo "  --execute-timeout N    Execute phase timeout in seconds (default: 3600)"
      echo "  --polish-timeout N     Polish phase timeout in seconds (default: 5400)"
      echo "  --regress-timeout N    Regress phase timeout in seconds (default: 9000)"
      echo "  --help                 Show this help"
      exit 0 ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        MAX_LOOPS="$1"
      else
        echo "ERROR: Unknown option '$1'. Use --help for usage."
        exit 1
      fi
      shift ;;
  esac
done

# ─── Setup ────────────────────────────────────────────────────────────

# Validate --only argument if provided
if [ -n "${ONLY_PHASE:-}" ]; then
  case "$ONLY_PHASE" in
    ideate|triage|execute|polish|regress|backlog) ;;
    *) echo "ERROR: Unknown phase '$ONLY_PHASE'. Must be: ideate, triage, execute, polish, regress, backlog"; exit 1 ;;
  esac
fi

# Validate BASE_BRANCH (reject chars that break sed or shell expansion)
if ! git check-ref-format --branch "$BASE_BRANCH" 2>/dev/null; then
  echo "ERROR: Invalid branch name '$BASE_BRANCH'"; exit 1
fi

# Auto-reduce regress timeout in quick mode
if [ "$REGRESS_QUICK" = true ] && [ "$REGRESS_TIMEOUT" = "9000" ]; then
  REGRESS_TIMEOUT=3600
fi

# Determine ideate prompt based on mode
if [ "$MODE" = "backtest" ]; then
  IDEATE_PROMPT="ideate-backtest"
elif [ "$MODE" = "exploration" ]; then
  IDEATE_PROMPT="ideate-exploration"
elif [ "$MODE" = "ui" ]; then
  IDEATE_PROMPT="ideate-ui"
else
  IDEATE_PROMPT="ideate"
fi

# ─── Mode-specific phase defaults ────────────────────────────────────
if [ "$MODE" = "user-only" ]; then
  if [ -z "$ONLY_PHASE" ]; then
    if [ -n "$SKIP_PHASES" ]; then
      SKIP_PHASES="${SKIP_PHASES},execute,polish,regress"
    else
      SKIP_PHASES="execute,polish,regress"
    fi
  fi
  if [ "$BACKLOG_INTERVAL_EXPLICIT" = false ]; then
    BACKLOG_INTERVAL=1
  fi
  if [ "$REVIEW_INTERVAL_EXPLICIT" = false ]; then
    REVIEW_INTERVAL=0
  fi
elif [ "$MODE" = "dev-only" ]; then
  if [ -z "$ONLY_PHASE" ]; then
    if [ -n "$SKIP_PHASES" ]; then
      SKIP_PHASES="${SKIP_PHASES},ideate,triage"
    else
      SKIP_PHASES="ideate,triage"
    fi
  fi
fi

# Validate prompt files exist
for phase in triage execute polish regress backlog; do
  if [ ! -f "$PROMPTS_DIR/${phase}.md" ]; then
    echo "ERROR: Missing prompt file: $PROMPTS_DIR/${phase}.md"
    exit 1
  fi
done
if [ ! -f "$PROMPTS_DIR/${IDEATE_PROMPT}.md" ]; then
  echo "ERROR: Missing prompt file: $PROMPTS_DIR/${IDEATE_PROMPT}.md"
  exit 1
fi

# Ensure claude runs from the repo root
cd "$REPO_ROOT"

# ─── Pre-flight: Refresh MCP OAuth tokens ────────────────────────────
if [ -x "$SCRIPT_DIR/refresh-mcp-oauth.sh" ]; then
  echo "Pre-flight: Checking MCP OAuth tokens..."
  if "$SCRIPT_DIR/refresh-mcp-oauth.sh" 2>&1; then
    echo "Pre-flight: MCP OAuth tokens OK"
  else
    echo "WARNING: MCP OAuth token refresh failed"
  fi
  echo ""
fi

# ─── Pre-flight: Check required env vars ─────────────────────────────
if [ "$HAS_CONFIG" = true ]; then
  PREFLIGHT_VARS=$(config_get_list "verification.preflight_env_vars" 2>/dev/null || true)
  if [ -n "$PREFLIGHT_VARS" ]; then
    echo "Pre-flight: Checking required environment variables..."
    MISSING_VARS=()
    while IFS= read -r var; do
      [ -z "$var" ] && continue
      if [ -z "${!var:-}" ]; then
        MISSING_VARS+=("$var")
      fi
    done <<< "$PREFLIGHT_VARS"
    if [ ${#MISSING_VARS[@]} -gt 0 ]; then
      echo "ERROR: Required environment variables not set: ${MISSING_VARS[*]}"
      echo "  Set them in your shell or in ${ENV_FILE}"
      exit 1
    fi
    echo "Pre-flight: All required env vars present."
  fi
fi

# ─── Pre-flight: Verify claude --print produces output ────────────────
echo "Pre-flight: Verifying claude --print output..."
_preflight_test_output=$(echo "respond with exactly: ok" | claude --print --output-format stream-json 2>/dev/null \
  | jq -r --unbuffered 'if .type == "assistant" then .message.content[]? | select(.type == "text") | .text elif .type == "result" and (.result // "") != "" then .result else empty end' 2>/dev/null || true)
if [ -z "$_preflight_test_output" ]; then
  echo "  FATAL: claude --print returned no output. Check your API key and CLI version."
  exit 1
else
  echo "Pre-flight: claude --print OK."
fi

# ─── Pre-flight: Safety warning for protected branches ────────────────
if [[ "$BASE_BRANCH" =~ ^(main|master|production|release)$ ]]; then
  _preflight_require_ci=$(config_get_default "pr_manager.require_ci" "true" 2>/dev/null || echo "true")
  if [ "$_preflight_require_ci" != "true" ]; then
    echo ""
    echo "WARNING: KitchenLoop is targeting '$BASE_BRANCH' with CI checks DISABLED."
    echo "  This means merged PRs will NOT wait for CI to pass."
    echo "  Set pr_manager.require_ci: true in kitchenloop.yaml for safer operation."
    echo ""
  fi
fi

# Initialize log
echo "# Kitchen Loop Log" >> "$LOG_FILE"
echo "Started: $(date)" >> "$LOG_FILE"
echo "Config: loops=$MAX_LOOPS skip=$SKIP_PHASES only=$ONLY_PHASE mode=$MODE review_interval=$REVIEW_INTERVAL" >> "$LOG_FILE"
echo "---" >> "$LOG_FILE"

# ─── Helper: should_skip ─────────────────────────────────────────────
should_skip() {
  local phase="$1"
  if [ -n "$ONLY_PHASE" ] && [ "$phase" != "$ONLY_PHASE" ]; then
    return 0
  fi
  if echo ",$SKIP_PHASES," | grep -q ",$phase,"; then
    return 0
  fi
  return 1
}

# ─── Helper: get_timeout ─────────────────────────────────────────────
get_timeout() {
  local phase="$1"
  case $phase in
    ideate)  echo "$IDEATE_TIMEOUT" ;;
    triage)  echo "$TRIAGE_TIMEOUT" ;;
    execute) echo "$EXECUTE_TIMEOUT" ;;
    polish)  echo "$POLISH_TIMEOUT" ;;
    regress) echo "$REGRESS_TIMEOUT" ;;
    backlog) echo "$BACKLOG_TIMEOUT" ;;
    *)       echo "1800" ;;
  esac
}

# ─── Helper: get_model ──────────────────────────────────────────────
get_model() {
  local phase="$1"
  case $phase in
    ideate)  echo "$IDEATE_MODEL" ;;
    triage)  echo "$TRIAGE_MODEL" ;;
    execute) echo "$EXECUTE_MODEL" ;;
    polish)  echo "$POLISH_MODEL" ;;
    regress) echo "$REGRESS_MODEL" ;;
    backlog) echo "$BACKLOG_MODEL" ;;
    review)  echo "$REVIEW_MODEL" ;;
    *)       echo "" ;;
  esac
}

# ─── Helper: run_claude_for_phase ────────────────────────────────────
# Runs claude with the correct model flag for a given phase.
# Reads prompt from stdin, writes output to stdout.
# Usage: preprocess_prompt ... | run_claude_for_phase "execute"
run_claude_for_phase() {
  local phase="$1"
  local model
  model=$(get_model "$phase")
  # Always use stream-json + jq extraction. The --print flag has a known bug
  # in Claude CLI v2.1.83+ where it returns empty output despite generating
  # content. stream-json is more reliable across all CLI versions.
  local -a cmd=(claude --dangerously-skip-permissions --print --output-format stream-json)
  if [ -n "$model" ]; then
    cmd+=(--model "$model")
  fi
  "${cmd[@]}" | jq -r --unbuffered '
    if .type == "assistant" then
      .message.content[]? | select(.type == "text") | .text
    elif .type == "result" and (.result // "") != "" then
      .result
    else
      empty
    end
  '
}

# ─── Helper: get_blocked_combos ───────────────────────────────────────
# Reads blocked combos from structured YAML first, falls back to markdown
# section in loop-state.md for backward compatibility.
get_blocked_combos() {
  # Try structured YAML file first (preferred)
  if [ "$HAS_CONFIG" = true ]; then
    local yaml_file
    yaml_file="$(path_blocked_combos)"
    if [ -f "$yaml_file" ] && command -v yq >/dev/null 2>&1; then
      local combos
      combos=$(yq -r '.blocked_combos[]? | .combo | to_entries | map(.key + ":" + .value) | join(" + ") + " — " + .reason' "$yaml_file" 2>/dev/null || echo "")
      if [ -n "$combos" ]; then
        echo "$combos"
        return
      fi
    fi
  fi

  # Fallback: parse markdown section from loop-state.md
  local state_file
  if [ "$HAS_CONFIG" = true ]; then
    state_file="$(path_loop_state)"
  else
    state_file="$1/docs/internal/loop-state.md"
  fi
  if [ ! -f "$state_file" ]; then
    echo ""
    return
  fi
  sed -n '/^## Blocked Combos/,/^## /{/^## Blocked Combos/d;/^## /d;/^$/d;/^#/d;/^(/d;/^<!--/,/-->/d;p;}' "$state_file"
}

# ─── Helper: check_iter_artifacts ─────────────────────────────────────
check_iter_artifacts() {
  local wt_path="$1"
  local issues=0
  local state_file
  if [ "$HAS_CONFIG" = true ]; then
    state_file="$(path_loop_state)"
    # Make relative to worktree
    state_file="${state_file#$REPO_ROOT/}"
  else
    state_file="docs/internal/loop-state.md"
  fi

  if [ -f "$wt_path/$state_file" ] && grep -q '<<<<<<<' "$wt_path/$state_file" 2>/dev/null; then
    echo "  [integrity] WARNING: Merge conflict markers in $state_file"
    issues=$((issues + 1))
  fi

  local iter_line
  iter_line=$(grep -c '\*\*Iteration\*\*:' "$wt_path/$state_file" 2>/dev/null || echo "0")
  if [ "$iter_line" -eq 0 ]; then
    echo "  [integrity] WARNING: loop-state.md missing iteration marker"
    issues=$((issues + 1))
  fi

  if [ "$issues" -gt 0 ]; then
    echo "  [integrity] $issues issue(s) found in iteration artifacts"
    return 1
  fi
  return 0
}

# ─── Helper: check_uat_verdicts ──────────────────────────────────────
# Scan UAT evidence files for verdicts. Returns 1 if any PRODUCT_FAIL or
# EVAL_CHEAT_FAIL found (merge should be blocked). UAT_SPEC_FAIL is logged
# but does not block. Returns 0 if no evidence files exist (UAT optional).
check_uat_verdicts() {
  local wt_path="$1"
  local uat_dir="$wt_path/$(path_uat_runs)"
  if [ ! -d "$uat_dir" ]; then
    return 0  # No UAT runs — UAT is optional
  fi

  local any_blocking=false
  local evidence_files
  evidence_files=$(find "$uat_dir" -name 'evidence.md' 2>/dev/null || true)
  if [ -z "$evidence_files" ]; then
    return 0
  fi

  while IFS= read -r evidence; do
    local ticket_id
    ticket_id=$(basename "$(dirname "$evidence")")
    local verdict
    verdict=$(grep -oP '\*\*(?:Overall|Verdict)\*\*:\s*\K\S+' "$evidence" 2>/dev/null | head -1)

    case "$verdict" in
      PASS)
        echo "  [uat-gate] $ticket_id: PASS"
        ;;
      PRODUCT_FAIL)
        echo "  [uat-gate] $ticket_id: PRODUCT_FAIL — merge blocked"
        any_blocking=true
        ;;
      EVAL_CHEAT_FAIL)
        echo "  [uat-gate] $ticket_id: EVAL_CHEAT_FAIL — merge blocked, flag for human review"
        any_blocking=true
        ;;
      UAT_SPEC_FAIL)
        echo "  [uat-gate] $ticket_id: UAT_SPEC_FAIL — logged (non-blocking)"
        ;;
      *)
        echo "  [uat-gate] $ticket_id: Unknown verdict '$verdict' — logged (non-blocking)"
        ;;
    esac
  done <<< "$evidence_files"

  if [ "$any_blocking" = true ]; then
    return 1
  fi
  return 0
}

# ─── Helper: record_iteration_metrics ────────────────────────────────
# Append iteration metrics to the metrics JSON file for drift tracking.
# Args: iteration_num regress_log_path
record_iteration_metrics() {
  local iter_num="$1"
  local regress_log="$2"
  local metrics_file

  if [ "$HAS_CONFIG" = true ]; then
    metrics_file="$(path_metrics)"
  else
    metrics_file="${REPO_ROOT}/.kitchenloop/metrics.json"
    mkdir -p "$(dirname "$metrics_file")"
  fi

  # Parse test results from regress log (common patterns across frameworks)
  local test_total=0 test_passed=0 test_failed=0 test_skipped=0
  if [ -f "$regress_log" ]; then
    # pytest: "X passed, Y failed, Z skipped"
    local pytest_line
    pytest_line=$(grep -oE '[0-9]+ passed' "$regress_log" 2>/dev/null | tail -1)
    if [ -n "$pytest_line" ]; then
      test_passed=$(echo "$pytest_line" | grep -oE '[0-9]+')
      test_failed=$(grep -oE '[0-9]+ failed' "$regress_log" 2>/dev/null | tail -1 | grep -oE '[0-9]+' || echo 0)
      test_skipped=$(grep -oE '[0-9]+ skipped' "$regress_log" 2>/dev/null | tail -1 | grep -oE '[0-9]+' || echo 0)
    fi
    # jest/mocha: "Tests: X passed, Y failed, Z total"
    local jest_total
    jest_total=$(grep -oE 'Tests:\s+[0-9]+' "$regress_log" 2>/dev/null | tail -1 | grep -oE '[0-9]+')
    if [ -n "$jest_total" ] && [ "$test_passed" -eq 0 ]; then
      test_total=$jest_total
      test_passed=$(grep -oE '[0-9]+ passed' "$regress_log" 2>/dev/null | tail -1 | grep -oE '[0-9]+' || echo 0)
      test_failed=$(grep -oE '[0-9]+ failed' "$regress_log" 2>/dev/null | tail -1 | grep -oE '[0-9]+' || echo 0)
    fi
    test_total=$((test_passed + test_failed + test_skipped))
  fi

  local pass_rate="0.0"
  if [ "$test_total" -gt 0 ]; then
    pass_rate=$(awk "BEGIN { printf \"%.4f\", $test_passed / $test_total }")
  fi

  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Parse tier from ideate log (machine-readable "TIER: T1|T2|T3" line)
  local tier="unknown"
  local ideate_log
  ideate_log=$(ls "$LOGS_DIR"/loop-$(printf '%03d' "$iter_num")-L*-ideate.log 2>/dev/null | head -1)
  if [ -n "$ideate_log" ] && [ -f "$ideate_log" ]; then
    local tier_match
    tier_match=$(grep -oE '^TIER: T[123]' "$ideate_log" 2>/dev/null | tail -1 || true)
    case "$tier_match" in
      "TIER: T1") tier="T1" ;;
      "TIER: T2") tier="T2" ;;
      "TIER: T3") tier="T3" ;;
    esac
  fi

  # Initialize metrics file if it doesn't exist
  if [ ! -f "$metrics_file" ]; then
    echo '{"iterations":[]}' > "$metrics_file"
  fi

  # Append iteration entry
  local updated
  updated=$(jq --argjson num "$iter_num" \
    --arg ts "$ts" \
    --argjson total "$test_total" \
    --argjson passed "$test_passed" \
    --argjson failed "$test_failed" \
    --argjson skipped "$test_skipped" \
    --argjson rate "$pass_rate" \
    --arg tier "$tier" \
    '.iterations += [{"num": $num, "ts": $ts, "test_total": $total, "test_passed": $passed, "test_failed": $failed, "test_skipped": $skipped, "pass_rate": $rate, "tier": $tier}]' \
    "$metrics_file" 2>/dev/null)

  if [ -n "$updated" ]; then
    echo "$updated" > "$metrics_file"
    echo "  [metrics] Recorded: tests=$test_total passed=$test_passed failed=$test_failed rate=$pass_rate tier=$tier"
  else
    echo "  [metrics] WARNING: Failed to update metrics file"
  fi
}

# ─── Helper: check_drift_thresholds ──────────────────────────────────
# Check for quality drift by examining trends in the metrics file.
# Returns 1 if pass_rate or test_count declining for N+ consecutive iterations.
check_drift_thresholds() {
  local metrics_file
  if [ "$HAS_CONFIG" = true ]; then
    metrics_file="$(path_metrics)"
  else
    metrics_file="${REPO_ROOT}/.kitchenloop/metrics.json"
  fi

  if [ ! -f "$metrics_file" ]; then
    return 0  # No metrics yet
  fi

  local decline_iters="${TEST_COUNT_DECLINE_ITERS:-3}"
  local count
  count=$(jq '.iterations | length' "$metrics_file" 2>/dev/null || echo 0)

  if [ "$count" -lt "$decline_iters" ]; then
    return 0  # Not enough data
  fi

  # Check pass_rate trend (last N iterations)
  local pass_rate_declining
  pass_rate_declining=$(jq --argjson n "$decline_iters" '
    .iterations[-$n:] as $last |
    [range(1; $last | length) | select($last[.].pass_rate < $last[. - 1].pass_rate)] |
    length == ($n - 1)
  ' "$metrics_file" 2>/dev/null || echo "false")

  if [ "$pass_rate_declining" = "true" ]; then
    echo "  [drift] WARNING: Pass rate declining for $decline_iters consecutive iterations"
    return 1
  fi

  # Check test_total trend (last N iterations)
  local test_count_declining
  test_count_declining=$(jq --argjson n "$decline_iters" '
    .iterations[-$n:] as $last |
    [range(1; $last | length) | select($last[.].test_total < $last[. - 1].test_total)] |
    length == ($n - 1)
  ' "$metrics_file" 2>/dev/null || echo "false")

  if [ "$test_count_declining" = "true" ]; then
    echo "  [drift] WARNING: Test count declining for $decline_iters consecutive iterations"
    return 1
  fi

  return 0
}

# ─── Helper: strip_ansi ───────────────────────────────────────────────
strip_ansi() {
  perl -pe 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b\([AB]//g; s/\x00//g'
}

# ─── Helper: build_project_context ────────────────────────────────────
# Reads project.context from config and formats it for prompt injection.
build_project_context() {
  if [ "$HAS_CONFIG" != true ]; then
    echo "(No project context configured. Add project.context to kitchenloop.yaml)"
    return
  fi
  local context
  context=$(config_get "project.context")
  if [ -n "$context" ]; then
    echo "$context"
  else
    # Fallback: generate minimal context from available config
    local name desc lang
    name=$(config_get "project.name")
    desc=$(config_get "project.description")
    lang=$(config_get "project.language")
    echo "Project: ${name} (${lang})"
    echo "Description: ${desc}"
    echo ""
    echo "(Add project.context to kitchenloop.yaml with usage instructions for better ideation)"
  fi
}

# ─── Helper: build_spec_surface ──────────────────────────────────────
# Reads spec dimensions from config and formats as readable text.
build_spec_surface() {
  if [ "$HAS_CONFIG" != true ]; then
    echo "(No spec surface configured)"
    return
  fi
  # List all dimension keys and their values
  local dimensions
  dimensions=$(yq '.spec.dimensions | keys | .[]' "$KITCHENLOOP_CONFIG" 2>/dev/null || true)
  if [ -z "$dimensions" ]; then
    echo "(No dimensions configured in spec.dimensions)"
    return
  fi
  for dim in $dimensions; do
    local values
    values=$(config_get_list "spec.dimensions.$dim" | paste -sd ', ' -)
    echo "- **${dim}**: ${values}"
  done
}

# ─── Helper: preprocess_prompt ────────────────────────────────────────
preprocess_prompt() {
  local prompt_file="$1"
  local blocked_combos
  blocked_combos=$(get_blocked_combos "${ITER_WORKTREE:-$REPO_ROOT}")
  if [ -z "$blocked_combos" ]; then
    blocked_combos="(none)"
  fi

  # Build coverage summary for template injection
  local coverage_summary="(no coverage data yet)"
  if [ "$HAS_CONFIG" = true ]; then
    local cov_file
    cov_file="$(path_coverage_matrix)"
    if [ -f "$cov_file" ] && command -v yq >/dev/null 2>&1; then
      local tested total pct
      tested=$(yq -r '.tested_combos // 0' "$cov_file" 2>/dev/null || echo 0)
      total=$(yq -r '.total_combos // 0' "$cov_file" 2>/dev/null || echo 0)
      pct=$(yq -r '.coverage_pct // 0' "$cov_file" 2>/dev/null || echo 0)
      if [ "$total" -gt 0 ] 2>/dev/null; then
        coverage_summary="Coverage: $tested/$total combos tested ($pct%)"
      fi
    fi
  fi

  # Build multi-line content for template injection
  local tmp_blocked tmp_context tmp_spec tmp_coverage
  tmp_blocked=$(mktemp)
  tmp_context=$(mktemp)
  tmp_spec=$(mktemp)
  tmp_coverage=$(mktemp)
  echo "$blocked_combos" > "$tmp_blocked"
  build_project_context > "$tmp_context"
  build_spec_surface > "$tmp_spec"
  echo "$coverage_summary" > "$tmp_coverage"

  # Escape BASE_BRANCH for sed (handle slashes, dots, etc.)
  local base_branch_escaped
  base_branch_escaped=$(printf '%s\n' "$BASE_BRANCH" | sed 's/[&/\]/\\&/g')

  # Read project name, description, and root for single-line substitution
  local project_name project_desc project_root project_root_directive
  project_name=$(config_get_default "project.name" "unknown")
  project_desc=$(config_get_default "project.description" "No description")
  project_root=$(config_get "project.root")

  # Build project root directive (only if project.root is set)
  local tmp_root_directive
  tmp_root_directive=$(mktemp)
  if [ -n "$project_root" ]; then
    cat > "$tmp_root_directive" << DIRECTIVE
**IMPORTANT — Project Root**: The project you are testing lives at \`${project_root}/\` within this repository.
\`cd ${project_root}\` before running any commands. All code changes, tests, and reports should be
relative to that directory. Do NOT modify files outside \`${project_root}/\` unless fixing a bug
in the framework that blocks your scenario.
DIRECTIVE
  else
    echo "" > "$tmp_root_directive"
  fi

  sed \
    -e "s|{{REPO_ROOT}}|${REPO_ROOT}|g" \
    -e "s|{{ITERATION_NUM}}|${ITER_NUM:-0}|g" \
    -e "s|{{ITER_WORKTREE}}|${ITER_WORKTREE:-$REPO_ROOT}|g" \
    -e "s|{{MODE}}|${MODE}|g" \
    -e "s|{{REGRESS_QUICK}}|${REGRESS_QUICK}|g" \
    -e "s|{{BASE_BRANCH}}|${base_branch_escaped}|g" \
    -e "s|{{TEST_COMMAND}}|${FULL_TEST_CMD}|g" \
    -e "s|{{QUICK_TEST_COMMAND}}|${QUICK_TEST_CMD}|g" \
    -e "s|{{LINT_COMMAND}}|${LINT_CMD}|g" \
    -e "s|{{SECURITY_COMMAND}}|${SECURITY_CMD}|g" \
    -e "s|{{SMOKE_COMMAND}}|${SMOKE_CMD}|g" \
    -e "s|{{COVERAGE_MATRIX_PATH}}|$(path_coverage_matrix)|g" \
    -e "s|{{STARVATION_MODE}}|${STARVATION_MODE:-false}|g" \
    -e "s|{{PROJECT_NAME}}|${project_name}|g" \
    -e "s|{{PROJECT_DESC}}|${project_desc}|g" \
    "$prompt_file" \
    | awk -v blocked="$tmp_blocked" -v context="$tmp_context" -v spec="$tmp_spec" -v rootdir="$tmp_root_directive" -v coverage="$tmp_coverage" '{
        if (index($0, "{{BLOCKED_COMBOS}}")) {
          while ((getline line < blocked) > 0) print line
          close(blocked)
        } else if (index($0, "{{PROJECT_CONTEXT}}")) {
          while ((getline line < context) > 0) print line
          close(context)
        } else if (index($0, "{{SPEC_SURFACE}}")) {
          while ((getline line < spec) > 0) print line
          close(spec)
        } else if (index($0, "{{PROJECT_ROOT_DIRECTIVE}}")) {
          while ((getline line < rootdir) > 0) print line
          close(rootdir)
        } else if (index($0, "{{COVERAGE_SUMMARY}}")) {
          while ((getline line < coverage) > 0) print line
          close(coverage)
        } else {
          print
        }
      }'
  rm -f "$tmp_blocked" "$tmp_context" "$tmp_spec" "$tmp_root_directive" "$tmp_coverage"
}

# ─── Helper: run_phase ───────────────────────────────────────────────
run_phase() {
  local phase="$1"
  local loop_num="$2"
  local prompt_name="${3:-$phase}"
  local cwd="${4:-$REPO_ROOT}"
  local timeout
  timeout=$(get_timeout "$phase")

  local log_num="${ITER_NUM:-$loop_num}"
  local phase_log="$LOGS_DIR/loop-$(printf '%03d' "$log_num")-L${loop_num}-${phase}.log"

  local model
  model=$(get_model "$phase")

  echo ""
  echo "  [$phase] Starting (timeout: ${timeout}s, model: ${model:-default}, cwd: $cwd)"
  echo "  [$phase] Live log: tail -f $phase_log"
  echo "  $(date '+%H:%M:%S') ──────────────────────────────"

  true > "$phase_log"
  local timed_out=false

  # Abort if worktree was cleaned up — never fall back to REPO_ROOT during a loop
  # run, as that would violate worktree isolation (AGENTS.md:39)
  if [ ! -d "$cwd" ]; then
    echo "  [$phase] ABORTED: worktree missing ($cwd) — cannot run phase without isolation"
    echo "$(date) | Loop $loop_num | $phase | mode=$MODE | ABORTED (worktree missing) | $phase_log" >> "$LOG_FILE"
    return 1
  fi

  local stderr_log="${phase_log%.log}-stderr.log"

  preprocess_prompt "$PROMPTS_DIR/${prompt_name}.md" \
    | (cd "$cwd" && { [ -f "$ENV_FILE" ] && set -a && source "$ENV_FILE" && set +a; } 2>/dev/null; run_claude_for_phase "$phase") \
    >> "$phase_log" 2>"$stderr_log" &
  local claude_pid=$!
  CHILD_PIDS+=("$claude_pid")

  # Heartbeat: print elapsed time every 5 min
  local start_ts
  start_ts=$(date +%s)
  (
    while true; do
      sleep 300
      local now elapsed_min
      now=$(date +%s)
      elapsed_min=$(( (now - start_ts) / 60 ))
      local remaining_min=$(( (timeout - (now - start_ts)) / 60 ))
      local last_progress=""
      if [ -f "$phase_log" ]; then
        last_progress=$(grep -v '^\s*$' "$phase_log" | grep -v '\.\.\. [0-9]*m elapsed' | tail -1 | head -c 120 || true)
      fi
      local msg="  [$phase] ... ${elapsed_min}m elapsed, ${remaining_min}m remaining ($(date '+%H:%M:%S'))"
      if [ -n "$last_progress" ]; then
        msg="$msg | last: ${last_progress}"
      fi
      echo "$msg" >> "$phase_log"
      echo "$msg"
    done
  ) &
  local heartbeat_pid=$!

  # Watchdog: kill entire process group on timeout (macOS zombie fix)
  (
    sleep "$timeout"
    touch "${phase_log}.timeout"
    # Kill process group to catch grandchildren (key macOS fix)
    local pgid
    pgid=$(ps -o pgid= -p "$claude_pid" 2>/dev/null | tr -d ' ')
    [ -n "$pgid" ] && kill -- -"$pgid" 2>/dev/null || kill "$claude_pid" 2>/dev/null || true
    sleep 10
    pgid=$(ps -o pgid= -p "$claude_pid" 2>/dev/null | tr -d ' ')
    [ -n "$pgid" ] && kill -9 -- -"$pgid" 2>/dev/null || kill -9 "$claude_pid" 2>/dev/null || true
  ) &
  local watchdog_pid=$!
  CHILD_PIDS+=("$watchdog_pid")

  # Startup watchdog: detect silent agent failures (0-byte log after 60s)
  (
    sleep 60
    if [ ! -s "$phase_log" ]; then
      echo "  [$phase] STARTUP FAILURE — 0 bytes after 60s" >> "$phase_log"
      echo "  [$phase] STARTUP FAILURE — 0 bytes after 60s, killing agent"
      local pgid
      pgid=$(ps -o pgid= -p "$claude_pid" 2>/dev/null | tr -d ' ')
      [ -n "$pgid" ] && kill -- -"$pgid" 2>/dev/null || kill "$claude_pid" 2>/dev/null || true
      touch "${phase_log}.startup_fail"
    fi
  ) &
  local startup_wdog=$!

  local exit_code=0
  wait "$claude_pid" 2>/dev/null || exit_code=$?
  remove_pid "$claude_pid"

  kill "$heartbeat_pid" 2>/dev/null || true; wait "$heartbeat_pid" 2>/dev/null 2>&1 || true
  kill "$watchdog_pid" 2>/dev/null || true; wait "$watchdog_pid" 2>/dev/null 2>&1 || true
  kill "$startup_wdog" 2>/dev/null || true; wait "$startup_wdog" 2>/dev/null 2>&1 || true
  remove_pid "$watchdog_pid"

  if [ -f "${phase_log}.timeout" ]; then
    timed_out=true
    rm -f "${phase_log}.timeout"
  fi

  # Check for startup failure
  local startup_failed=false
  if [ -f "${phase_log}.startup_fail" ]; then
    startup_failed=true
    rm -f "${phase_log}.startup_fail"
  fi

  # Log stderr if non-empty
  if [ -s "$stderr_log" ]; then
    echo "  [$phase] stderr captured ($(wc -l < "$stderr_log" | tr -d ' ') lines): $stderr_log"
  else
    rm -f "$stderr_log"
  fi

  # Sentinel check: verify the agent actually started producing output
  # Use prompt_name (not phase) since sub-prompts emit different sentinels
  # e.g. ideate-backtest emits [ideate-backtest] STARTED, not [ideate] STARTED
  if [ -s "$phase_log" ] && ! grep -q "\[${prompt_name}\] STARTED" "$phase_log" 2>/dev/null; then
    echo "  [$phase] WARNING: no sentinel line found (expected [${prompt_name}] STARTED) — agent may not have initialized correctly"
  fi

  # Exit-code diagnostics
  if [ "$startup_failed" = true ]; then
    echo "  [$phase] STARTUP FAILURE — agent produced no output within 60s  (log: $phase_log)"
    echo "$(date) | Loop $loop_num | $phase | mode=$MODE | STARTUP_FAIL | $phase_log" >> "$LOG_FILE"
    return 1
  elif [ "$timed_out" = true ]; then
    echo "  [$phase] TIMEOUT after ${timeout}s  (log: $phase_log)"
    echo "$(date) | Loop $loop_num | $phase | mode=$MODE | TIMEOUT (${timeout}s) | $phase_log" >> "$LOG_FILE"
    return 1
  elif [ "$exit_code" -ne 0 ]; then
    local diag="exit $exit_code"
    case $exit_code in
      124) diag="timeout (exit 124)" ;;
      137) diag="SIGKILL/OOM (exit 137)" ;;
      143) diag="SIGTERM (exit 143)" ;;
    esac
    echo "  [$phase] FAILED ($diag)  (log: $phase_log)"
    # Include last 5 lines of log for quick triage
    echo "  [$phase] Last output:"
    tail -5 "$phase_log" 2>/dev/null | sed 's/^/    /' || true
    echo "$(date) | Loop $loop_num | $phase | mode=$MODE | FAILED ($diag) | $phase_log" >> "$LOG_FILE"
    return 1
  else
    echo "  [$phase] DONE  (log: $phase_log)"
    echo "$(date) | Loop $loop_num | $phase | mode=$MODE | OK | $phase_log" >> "$LOG_FILE"
    return 0
  fi
}

# ─── Helper: run_phase_hook ───────────────────────────────────────────
# Checks for optional pre/post hook prompts (e.g., triage-preflight.md,
# triage-dedup-sweep.md) and runs them if present.
run_phase_hook() {
  local phase="$1" hook="$2" loop_num="$3" cwd="${4:-$REPO_ROOT}"
  local hook_prompt="$PROMPTS_DIR/${phase}-${hook}.md"
  if [ -f "$hook_prompt" ]; then
    echo "  [${phase}] Running ${hook} hook..."
    run_phase "${phase}-${hook}" "$loop_num" "${phase}-${hook}" "$cwd" || \
      echo "  [${phase}] ${hook} hook failed (non-critical)"
  fi
}

# ─── Helper: get_iteration_number ─────────────────────────────────────
get_iteration_number() {
  local state_file
  if [ "$HAS_CONFIG" = true ]; then
    state_file="$(path_loop_state)"
    state_file="${state_file#$REPO_ROOT/}"
  else
    state_file="docs/internal/loop-state.md"
  fi
  local content
  content=$(git -C "$REPO_ROOT" show "origin/${BASE_BRANCH}:${state_file}" 2>/dev/null || true)
  if [ -n "$content" ]; then
    local num
    num=$(echo "$content" | sed -n 's/.*\*\*Iteration\*\*: *\([0-9][0-9]*\).*/\1/p' | tail -1)
    echo "${num:-0}"
  else
    echo "0"
  fi
}

# ─── Helper: create_iter_worktree ─────────────────────────────────────
create_iter_worktree() {
  local iter_num="$1"
  local wt_path
  if [ "$HAS_CONFIG" = true ]; then
    wt_path="$(path_iteration_worktree "$iter_num")"
  else
    wt_path="$REPO_ROOT/.claude/worktrees/kitchen-iter-${iter_num}"
  fi
  local branch="${ITER_BRANCH_PREFIX}-${iter_num}"

  git -C "$REPO_ROOT" fetch origin "$BASE_BRANCH" >&2

  git -C "$REPO_ROOT" worktree prune >/dev/null 2>&1 || true
  if [ -d "$wt_path" ]; then
    echo "  [worktree] Removing stale worktree: $wt_path" >&2
    git -C "$REPO_ROOT" worktree remove --force "$wt_path" >/dev/null 2>&1 || rm -rf "$wt_path"
  fi
  if git -C "$REPO_ROOT" rev-parse --verify "$branch" >/dev/null 2>&1; then
    local ahead_count
    ahead_count=$(git -C "$REPO_ROOT" rev-list --count "origin/${BASE_BRANCH}..$branch" 2>/dev/null || echo 0)
    if [ "$ahead_count" -gt 0 ]; then
      echo "  [worktree] ERROR: Refusing to delete $branch ($ahead_count unpushed commit(s))" >&2
      return 1
    fi
    # Safety: check for open PR before deleting
    if command -v gh >/dev/null 2>&1; then
      local open_pr_count
      open_pr_count=$(gh pr list --head "$branch" --state open --json number --jq 'length' 2>/dev/null || echo 0)
      if [ "$open_pr_count" -gt 0 ]; then
        echo "  [worktree] WARNING: $branch has an open PR — closing before delete" >&2
        gh pr close "$branch" 2>/dev/null || true
      fi
    fi
    # Check if remote branch exists (safe to delete local-only)
    if git -C "$REPO_ROOT" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
      echo "  [worktree] Remote branch exists, deleting remote first" >&2
      git -C "$REPO_ROOT" push origin --delete "$branch" 2>/dev/null || true
    fi
    # Handle stale worktree holding the branch
    git -C "$REPO_ROOT" worktree prune >/dev/null 2>&1 || true
    echo "  [worktree] Deleting orphan branch: $branch" >&2
    git -C "$REPO_ROOT" branch -D "$branch" >/dev/null 2>&1 || true
  fi

  if ! git -C "$REPO_ROOT" worktree add "$wt_path" -b "$branch" "origin/${BASE_BRANCH}" >&2; then
    echo "  [worktree] ERROR: Failed to create worktree $wt_path" >&2
    return 1
  fi

  # Copy env file if exists
  local env_path="$REPO_ROOT/$ENV_FILE"
  if [ -f "$env_path" ]; then
    cp "$env_path" "$wt_path/$ENV_FILE"
    echo "  [worktree] Copied $ENV_FILE from repo root" >&2
  fi

  echo "$wt_path"
}

# ─── Helper: commit_iter_artifacts ────────────────────────────────────
commit_iter_artifacts() {
  local wt_path="$1" iter_num="$2" phase="$3"
  local branch="${ITER_BRANCH_PREFIX}-${iter_num}"

  echo "  [$phase] Committing deliverables..."

  echo "  [$phase] Working tree status (untracked + modified):"
  git -C "$wt_path" status --porcelain -uall 2>/dev/null \
    | { grep -E '^(\?\?|.M| M|A )' || true; } \
    | head -20 \
    | while IFS= read -r line; do echo "    $line"; done
  echo "  [$phase] ---"

  # Resolve merge conflicts
  local unmerged
  unmerged=$(git -C "$wt_path" diff --name-only --diff-filter=U 2>/dev/null || true)
  if [ -n "$unmerged" ]; then
    echo "  [$phase] WARNING: Unmerged files detected, resolving with ours before commit"
    echo "$unmerged" | while IFS= read -r f; do
      git -C "$wt_path" checkout --ours "$f" 2>/dev/null || true
      git -C "$wt_path" add "$f" 2>/dev/null || true
    done
    git -C "$wt_path" commit --no-edit 2>/dev/null || true
  fi

  # Stage deliverables from config paths
  if [ "$HAS_CONFIG" = true ]; then
    local reports_rel scenarios_rel loop_state_rel patterns_rel
    reports_rel="$(path_reports)"; reports_rel="${reports_rel#$REPO_ROOT/}"
    scenarios_rel="$(path_scenarios)"; scenarios_rel="${scenarios_rel#$REPO_ROOT/}"
    loop_state_rel="$(path_loop_state)"; loop_state_rel="${loop_state_rel#$REPO_ROOT/}"
    patterns_rel="$(path_patterns)"; patterns_rel="${patterns_rel#$REPO_ROOT/}"

    for path in "$reports_rel" "$scenarios_rel" "$loop_state_rel" "$patterns_rel"; do
      git -C "$wt_path" add "$path" 2>/dev/null || true
    done

    if [ "${MODE:-}" = "ui" ]; then
      local ui_state_rel ui_runs_rel
      ui_state_rel="$(path_ui_test_state)"; ui_state_rel="${ui_state_rel#$REPO_ROOT/}"
      ui_runs_rel="$(path_ui_test_runs)"; ui_runs_rel="${ui_runs_rel#$REPO_ROOT/}"
      git -C "$wt_path" add "$ui_state_rel" "$ui_runs_rel" 2>/dev/null || true
    fi
  else
    for path in docs/internal/reports/ docs/internal/loop-state.md scenarios/ memory/; do
      git -C "$wt_path" add "$path" 2>/dev/null || true
    done
    if [ "${MODE:-}" = "ui" ]; then
      git -C "$wt_path" add ".kitchenloop/ui-test-state.json" ".kitchenloop/ui-test-runs/" 2>/dev/null || true
    fi
  fi

  # Catch-all for notes
  git -C "$wt_path" add notes/ 2>/dev/null || true

  if git -C "$wt_path" diff --cached --quiet 2>/dev/null; then
    echo "  [$phase] No new artifacts to commit (working tree clean, nothing staged)."
    return 0
  fi

  echo "  [$phase] Staged files:"
  git -C "$wt_path" diff --cached --name-only 2>/dev/null | while IFS= read -r f; do
    echo "    + $f"
  done

  if git -C "$wt_path" commit \
    -m "chore: kitchenloop iter ${iter_num} - ${phase} artifacts (auto-commit)"; then
    if git -C "$wt_path" push origin "$branch" 2>&1; then
      echo "  [$phase] Artifacts committed and pushed."
      # Verify push
      local local_sha remote_sha
      local_sha=$(git -C "$wt_path" rev-parse HEAD 2>/dev/null)
      git -C "$wt_path" fetch origin "$branch" 2>/dev/null || true
      remote_sha=$(git -C "$wt_path" rev-parse "origin/$branch" 2>/dev/null || echo "")
      if [ "$local_sha" != "$remote_sha" ]; then
        echo "  [$phase] WARNING: Push verification failed, retrying..."
        git -C "$wt_path" push origin "$branch" --force-with-lease 2>&1 || \
          echo "  [$phase] ERROR: Retry push also failed."
      fi
    else
      echo "  [$phase] WARNING: Push failed -- retrying with force-with-lease..."
      if ! git -C "$wt_path" push origin "$branch" --force-with-lease 2>&1; then
        echo "  [$phase] ERROR: All push attempts failed. Artifacts committed locally only."
        echo "$(date) | Iter $iter_num | $phase | PUSH FAILED" >> "$LOG_FILE"
      fi
    fi
  else
    echo "  [$phase] WARNING: Commit failed."
  fi
}

# ─── Helper: sync_iter_worktree ───────────────────────────────────────
sync_iter_worktree() {
  local wt_path="$1"
  if [ ! -d "$wt_path" ]; then
    echo "  [sync] SKIP — worktree directory missing: $wt_path"
    return 0
  fi
  echo "  [sync] Merging origin/${BASE_BRANCH} into worktree..."
  git -C "$wt_path" fetch origin "$BASE_BRANCH"
  if ! git -C "$wt_path" merge "origin/${BASE_BRANCH}" --no-edit 2>/dev/null; then
    echo "  [sync] Merge conflict -- auto-resolving all conflicts (ours)"
    local conflicted
    conflicted=$(git -C "$wt_path" diff --name-only --diff-filter=U 2>/dev/null || true)
    if [ -n "$conflicted" ]; then
      echo "$conflicted" | while IFS= read -r f; do
        echo "  [sync]   resolving: $f"
        git -C "$wt_path" checkout --ours "$f" 2>/dev/null || true
        git -C "$wt_path" add "$f" 2>/dev/null || true
      done
    fi
    if ! git -C "$wt_path" commit --no-edit 2>/dev/null; then
      echo "  [sync] WARNING: Could not complete merge, aborting"
      git -C "$wt_path" merge --abort 2>/dev/null || true
    fi
  fi
}

# ─── Helper: merge_iter_back ──────────────────────────────────────────
# Merge the iteration branch into $BASE_BRANCH. Tries fast-forward first,
# falls back to a merge commit, then to a PR if direct merge isn't possible.
merge_iter_back() {
  local wt_path="$1" iter_num="$2"
  local branch="${ITER_BRANCH_PREFIX}-${iter_num}"

  echo "  [merge] Pushing iteration branch and merging to ${BASE_BRANCH}..."
  # Use worktree if available, fall back to REPO_ROOT (worktree may be gone after polish)
  local git_dir="$wt_path"
  [ -d "$git_dir" ] || git_dir="$REPO_ROOT"
  if ! git -C "$git_dir" push origin "$branch" 2>&1; then
    local local_sha remote_sha
    local_sha=$(git -C "$git_dir" rev-parse HEAD 2>/dev/null || echo "unknown")
    remote_sha=$(git -C "$git_dir" rev-parse "origin/$branch" 2>/dev/null || echo "unknown")
    echo "  [merge] WARNING: Push of $branch failed (local=$local_sha remote=$remote_sha)"
    # C4: Retry with --force-with-lease
    echo "  [merge] Retrying push with --force-with-lease..."
    if ! git -C "$git_dir" push origin "$branch" --force-with-lease 2>&1; then
      echo "  [merge] ERROR: Push retry also failed."
      echo "$(date) | Iter $iter_num | merge | PUSH FAILED (local=$local_sha remote=$remote_sha)" >> "$LOG_FILE"
      return 1
    fi
    echo "  [merge] Push succeeded on retry with --force-with-lease."
  fi

  # Check if CI is required (determines merge strategy)
  local require_ci
  require_ci=$(config_get_default "pr_manager.require_ci" "true" 2>/dev/null || echo "true")

  # Attempt 1: fast-forward $BASE_BRANCH (fastest, no PR overhead)
  if [ "$require_ci" != "true" ]; then
    local ff_output
    if ff_output=$(git push origin "$branch:$BASE_BRANCH" 2>&1); then
      echo "  [merge] $BASE_BRANCH fast-forwarded with iteration $iter_num changes."
      return 0
    fi
    echo "  [merge] Fast-forward failed: $ff_output"

    # Attempt 2: re-sync worktree and try fast-forward again
    echo "  [merge] Non-fast-forward — re-syncing and retrying"
    sync_iter_worktree "$wt_path"
    git -C "$wt_path" push origin "$branch" --force-with-lease 2>&1 || true
    if ff_output=$(git push origin "$branch:$BASE_BRANCH" 2>&1); then
      echo "  [merge] $BASE_BRANCH fast-forwarded after re-sync."
      return 0
    fi
    echo "  [merge] Fast-forward after re-sync failed: $ff_output"

    # Attempt 3: merge commit via temporary clone
    echo "  [merge] Creating merge commit..."
    local tmp_merge_dir
    tmp_merge_dir=$(mktemp -d)
    if git clone --depth=50 --branch "$BASE_BRANCH" --single-branch \
        "$(git -C "$wt_path" remote get-url origin)" "$tmp_merge_dir" 2>/dev/null; then
      if git -C "$tmp_merge_dir" fetch origin "$branch" 2>/dev/null && \
         git -C "$tmp_merge_dir" merge FETCH_HEAD \
          --no-edit -m "chore: merge ${branch} into $BASE_BRANCH" 2>/dev/null; then
        if git -C "$tmp_merge_dir" push origin "$BASE_BRANCH" 2>/dev/null; then
          echo "  [merge] $BASE_BRANCH updated via merge commit."
          rm -rf "$tmp_merge_dir"
          return 0
        fi
      fi
    fi
    rm -rf "$tmp_merge_dir"
  fi

  # Attempt 4 (or primary path when CI required): Create a PR
  # Pre-check: skip PR creation if branch has 0 commits ahead of base
  local commit_count
  commit_count=$(git -C "$wt_path" rev-list --count "origin/${BASE_BRANCH}..${branch}" 2>/dev/null || echo 0)
  if [ "$commit_count" -eq 0 ]; then
    echo "  [merge] Skipping PR creation — branch $branch has 0 commits ahead of $BASE_BRANCH"
    echo "  [merge]   branch HEAD: $(git -C "$wt_path" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "  [merge]   base HEAD:   $(git -C "$wt_path" rev-parse "origin/$BASE_BRANCH" 2>/dev/null || echo unknown)"
    echo "$(date) | Iter $iter_num | merge | SKIPPED — 0 commits ahead" >> "$LOG_FILE"
    return 0
  fi

  echo "  [merge] Creating PR for iteration $iter_num ($commit_count commits ahead)..."
  local pr_url
  pr_url=$(gh pr create \
    --repo "$(git -C "$wt_path" remote get-url origin)" \
    --base "$BASE_BRANCH" \
    --head "$branch" \
    --title "chore(loop): iteration ${iter_num} — merge into ${BASE_BRANCH}" \
    --body "$(cat <<PR_BODY
Automated KitchenLoop iteration $iter_num.

- Branch: \`$branch\`
- Mode: ${MODE:-strategy}
- Regress gate: **passed** (shell-enforced)

Created by KitchenLoop orchestrator.
PR_BODY
)" \
    2>&1) || true

  # If gh pr create failed with "no commits between", don't retry
  if echo "$pr_url" | grep -qi "no commits between"; then
    echo "  [merge] No commits between branches — nothing to merge (artifacts already on $BASE_BRANCH?)"
    echo "$(date) | Iter $iter_num | merge | SKIPPED — no commits between branches" >> "$LOG_FILE"
    return 0
  fi

  if [ -n "$pr_url" ] && echo "$pr_url" | grep -q "http"; then
    echo "  [merge] PR created: $pr_url"
    echo "$(date) | Iter $iter_num | merge | PR: $pr_url" >> "$LOG_FILE"

    # If CI is not required, attempt to merge the PR immediately
    if [ "$require_ci" != "true" ]; then
      echo "  [merge] CI not required — attempting immediate PR merge..."
      if gh pr merge "$pr_url" --merge --delete-branch 2>&1; then
        echo "  [merge] PR merged successfully."
        return 0
      else
        echo "  [merge] Auto-merge failed — PR remains open for manual review."
      fi
    else
      echo "  [merge] PR left open for CI checks and review."
    fi
    return 0
  fi

  echo "  [merge] WARNING: All merge attempts failed."
  echo "  [merge] Manual merge required: git merge origin/$branch into ${BASE_BRANCH}"
  echo "$(date) | Iter $iter_num | merge | FAILED -- no PR" >> "$LOG_FILE"
  return 1
}

# ─── Helper: verify_merge ────────────────────────────────────────────
verify_merge() {
  local iter_num="$1"
  local branch="${ITER_BRANCH_PREFIX}-${iter_num}"

  git -C "$REPO_ROOT" fetch origin "$BASE_BRANCH" "$branch" 2>/dev/null || return 0

  local merge_base
  merge_base=$(git -C "$REPO_ROOT" merge-base "origin/${BASE_BRANCH}" "origin/$branch" 2>/dev/null || true)
  if [ -z "$merge_base" ]; then
    return 0
  fi

  local scenarios_rel=""
  local reports_rel=""
  if [ "$HAS_CONFIG" = true ]; then
    scenarios_rel="$(path_scenarios)"; scenarios_rel="${scenarios_rel#$REPO_ROOT/}/"
    reports_rel="$(path_reports)"; reports_rel="${reports_rel#$REPO_ROOT/}/"
  else
    scenarios_rel="scenarios/"
    reports_rel="docs/internal/reports/"
  fi

  local iter_files
  iter_files=$(git -C "$REPO_ROOT" diff --name-only --diff-filter=A \
    "$merge_base" "origin/$branch" -- \
    "$scenarios_rel" "$reports_rel" 2>/dev/null | grep -v '^$' || true)

  if [ -z "$iter_files" ]; then
    return 0
  fi

  local missing=0
  while IFS= read -r f; do
    if ! git -C "$REPO_ROOT" cat-file -e "origin/${BASE_BRANCH}:$f" 2>/dev/null; then
      echo "  [verify] WARNING: $f exists on $branch but NOT on ${BASE_BRANCH}"
      missing=$((missing + 1))
    fi
  done <<< "$iter_files"

  if [ "$missing" -gt 0 ]; then
    echo "  [verify] $missing file(s) missing from ${BASE_BRANCH}."
    echo "$(date) | Iter $iter_num | verify | WARNING: $missing deliverable(s) missing" >> "$LOG_FILE"
    return 1
  else
    echo "  [verify] All iteration deliverables confirmed on ${BASE_BRANCH}."
    return 0
  fi
}

# ─── Helper: cleanup_iter_worktree ────────────────────────────────────
cleanup_iter_worktree() {
  local wt_path="$1" iter_num="$2"
  echo "  [cleanup] Removing iteration worktree..."
  git -C "$REPO_ROOT" worktree remove "$wt_path" 2>/dev/null || rm -rf "$wt_path"
  git -C "$REPO_ROOT" branch -D "${ITER_BRANCH_PREFIX}-${iter_num}" 2>/dev/null || true
  git -C "$REPO_ROOT" push origin --delete "${ITER_BRANCH_PREFIX}-${iter_num}" 2>/dev/null || true
  ITER_WORKTREE=""
}

# ─── Helper: run_auto_review ──────────────────────────────────────────
run_auto_review() {
  local iter_start="$1"
  local iter_end="$2"

  echo ""
  echo "  --- Auto-Review: Iterations ${iter_start}-${iter_end} ---"

  local review_log="$LOGS_DIR/review-iter-${iter_start}-${iter_end}.log"
  echo "  [review] Live log: tail -f $review_log"

  local reports_path
  if [ "$HAS_CONFIG" = true ]; then
    reports_path=$(path_reports)
    reports_path="${reports_path#$REPO_ROOT/}"
  else
    reports_path="docs/internal/reports"
  fi

  local review_prompt
  review_prompt="Review iterations ${iter_start} through ${iter_end} of the Kitchen Loop.
Run /loop-review for these iterations. This is an autonomous run -- do NOT use AskUserQuestion or EnterPlanMode.
For loop improvement tickets, auto-create Blocker/Important findings only (skip Observations).
Write the report to ${reports_path}/loop-review-iter-${iter_start}-${iter_end}.md"

  echo "$review_prompt" \
    | (cd "${ITER_WORKTREE:-$REPO_ROOT}" && run_claude_for_phase "review") \
    >> "$review_log" 2>&1 &
  local review_pid=$!
  CHILD_PIDS+=("$review_pid")

  (
    sleep 5400
    touch "${review_log}.timeout"
    kill "$review_pid" 2>/dev/null || true
    sleep 10; kill -9 "$review_pid" 2>/dev/null || true
  ) &
  local wdog=$!

  wait "$review_pid" 2>/dev/null || true
  remove_pid "$review_pid"
  kill "$wdog" 2>/dev/null || true; wait "$wdog" 2>/dev/null 2>&1 || true

  if [ -f "${review_log}.timeout" ]; then
    rm -f "${review_log}.timeout"
    echo "  [review] TIMEOUT (non-critical)"
    echo "$(date) | Review iter ${iter_start}-${iter_end} | TIMEOUT | $review_log" >> "$LOG_FILE"
  else
    echo "  [review] DONE"
    echo "$(date) | Review iter ${iter_start}-${iter_end} | OK | $review_log" >> "$LOG_FILE"
  fi
}

# ─── Helper: clean_agent_junk ────────────────────────────────────────
clean_agent_junk() {
  local target_dir="${1:-$REPO_ROOT}"
  local count=0
  while IFS= read -r -d '' f; do
    rm -- "$f" 2>/dev/null && count=$((count + 1))
  done < <(find "$target_dir" -maxdepth 1 -type f \( \
    -name '=== *' -o -name '--- *' -o -name 'echo' \
    -o -name 'Exit*' -o -name 'Run complete*' -o -name 'Run completed*' \
  \) -print0 2>/dev/null)
  [ "$count" -gt 0 ] && echo "  [cleanup] Removed $count agent junk file(s)"
  return 0
}

# ─── Helper: sync_loop_state_to_base ─────────────────────────────────
# After regress, copy loop-state.md directly to $BASE_BRANCH so the loop
# never loses self-awareness even if the iteration branch PR isn't merged.
# This decouples loop-state persistence from worktree lifecycle.
sync_loop_state_to_base() {
  local wt_path="$1" iter_num="$2"
  local state_file
  if [ "$HAS_CONFIG" = true ]; then
    state_file="$(path_loop_state)"
    state_file="$wt_path/${state_file#$REPO_ROOT/}"
  else
    state_file="$wt_path/docs/internal/loop-state.md"
  fi

  if [ ! -f "$state_file" ]; then
    echo "  [loop-state-sync] WARNING: loop-state.md not found in worktree, skipping"
    return 0
  fi

  # Stamp current iteration number into the worktree's loop-state.md before syncing
  # Without this, the file is never updated between auto-reviews and the counter stalls
  sed -i.bak "s/\*\*Iteration\*\*: *[0-9]*/\*\*Iteration\*\*: $iter_num/" "$state_file" 2>/dev/null || true
  sed -i.bak "s/\*\*Mode\*\*: *[a-z-]*/\*\*Mode\*\*: $MODE/" "$state_file" 2>/dev/null || true
  rm -f "${state_file}.bak"

  echo "  [loop-state-sync] Syncing loop-state.md directly to $BASE_BRANCH..."

  local tmp_dir
  tmp_dir=$(mktemp -d)
  local remote_url
  remote_url=$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null)

  if git clone --depth=5 --branch "$BASE_BRANCH" --single-branch "$remote_url" "$tmp_dir" 2>/dev/null; then
    # Guard: don't overwrite a newer iteration already on the base branch
    local state_rel="${state_file#$wt_path/}"
    local remote_state="$tmp_dir/$state_rel"
    if [ -f "$remote_state" ]; then
      local remote_iter
      remote_iter=$(sed -n 's/.*\*\*Iteration\*\*: *\([0-9][0-9]*\).*/\1/p' "$remote_state" | tail -1)
      if [ -n "$remote_iter" ] && [ "$remote_iter" -ge "$iter_num" ]; then
        echo "  [loop-state-sync] Skipping: $BASE_BRANCH already has iteration $remote_iter (>= $iter_num)"
        rm -rf "$tmp_dir"
        return 0
      fi
    fi

    mkdir -p "$(dirname "$tmp_dir/$state_rel")"
    cp "$state_file" "$tmp_dir/$state_rel"

    if git -C "$tmp_dir" diff --quiet -- "$state_rel" 2>/dev/null; then
      echo "  [loop-state-sync] loop-state.md already up-to-date on $BASE_BRANCH"
    else
      git -C "$tmp_dir" add "$state_rel"
      if git -C "$tmp_dir" commit -m "chore: update loop-state to iter $iter_num (auto-sync)" 2>/dev/null; then
        if git -C "$tmp_dir" push origin "$BASE_BRANCH" 2>/dev/null; then
          echo "  [loop-state-sync] loop-state.md synced to $BASE_BRANCH (iter $iter_num)"
        else
          echo "  [loop-state-sync] WARNING: push to $BASE_BRANCH failed (non-critical)"
        fi
      fi
    fi
  else
    echo "  [loop-state-sync] WARNING: could not clone $BASE_BRANCH (non-critical)"
  fi

  rm -rf "$tmp_dir"
}

# ─── Helper: persist_reports_to_main ──────────────────────────────────
# Push reports directly to BASE_BRANCH so they're visible even if the
# iteration branch PR hasn't merged yet.
persist_reports_to_main() {
  local wt_path="$1" iter_num="$2"
  local reports_rel
  if [ "$HAS_CONFIG" = true ]; then
    reports_rel="$(path_reports)"; reports_rel="${reports_rel#$REPO_ROOT/}"
  else
    reports_rel="docs/internal/reports"
  fi

  local reports_src="$wt_path/$reports_rel"
  if [ ! -d "$reports_src" ] || [ -z "$(ls -A "$reports_src" 2>/dev/null)" ]; then
    return 0
  fi

  echo "  [persist-reports] Syncing reports to $BASE_BRANCH..."
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local remote_url
  remote_url=$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null)

  if git clone --depth=5 --branch "$BASE_BRANCH" --single-branch "$remote_url" "$tmp_dir" 2>/dev/null; then
    mkdir -p "$tmp_dir/$reports_rel"
    cp -R "$reports_src/"* "$tmp_dir/$reports_rel/" 2>/dev/null || true

    if ! git -C "$tmp_dir" diff --quiet -- "$reports_rel" 2>/dev/null || \
       [ -n "$(git -C "$tmp_dir" ls-files --others -- "$reports_rel" 2>/dev/null)" ]; then
      git -C "$tmp_dir" add "$reports_rel"
      if git -C "$tmp_dir" commit -m "chore: persist reports from iter $iter_num (auto-sync)" 2>/dev/null; then
        if git -C "$tmp_dir" push origin "$BASE_BRANCH" 2>/dev/null; then
          echo "  [persist-reports] Reports synced to $BASE_BRANCH (iter $iter_num)"
        else
          echo "  [persist-reports] WARNING: push failed (non-critical)"
        fi
      fi
    else
      echo "  [persist-reports] Reports already up-to-date on $BASE_BRANCH"
    fi
  else
    echo "  [persist-reports] WARNING: could not clone $BASE_BRANCH (non-critical)"
  fi

  rm -rf "$tmp_dir"
}

# ─── Helper: persist_ui_state_to_main ─────────────────────────────────
# Push ui-test-state.json directly to BASE_BRANCH so flow progression
# persists across iterations even before the iteration PR merges.
persist_ui_state_to_main() {
  local wt_path="$1" iter_num="$2"
  local state_rel
  if [ "$HAS_CONFIG" = true ]; then
    state_rel="$(path_ui_test_state)"; state_rel="${state_rel#$REPO_ROOT/}"
  else
    state_rel=".kitchenloop/ui-test-state.json"
  fi

  local state_src="$wt_path/$state_rel"
  if [ ! -f "$state_src" ]; then
    return 0
  fi

  echo "  [ui-state-sync] Syncing ui-test-state.json to $BASE_BRANCH..."
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local remote_url
  remote_url=$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null)

  if git clone --depth=5 --branch "$BASE_BRANCH" --single-branch "$remote_url" "$tmp_dir" 2>/dev/null; then
    mkdir -p "$tmp_dir/$(dirname "$state_rel")"
    cp "$state_src" "$tmp_dir/$state_rel"

    if git -C "$tmp_dir" diff --quiet -- "$state_rel" 2>/dev/null; then
      echo "  [ui-state-sync] ui-test-state.json already up-to-date on $BASE_BRANCH"
    else
      git -C "$tmp_dir" add "$state_rel"
      if git -C "$tmp_dir" commit -m "chore: sync ui-test-state to iter $iter_num (auto-sync)" 2>/dev/null; then
        if git -C "$tmp_dir" push origin "$BASE_BRANCH" 2>/dev/null; then
          echo "  [ui-state-sync] ui-test-state.json synced to $BASE_BRANCH (iter $iter_num)"
        else
          echo "  [ui-state-sync] WARNING: push to $BASE_BRANCH failed (non-critical)"
        fi
      fi
    fi
  else
    echo "  [ui-state-sync] WARNING: could not clone $BASE_BRANCH (non-critical)"
  fi

  rm -rf "$tmp_dir"
}

# ─── Main Loop ────────────────────────────────────────────────────────
echo ""
echo "==========================================================="
echo "  Kitchen Loop — the Loop that Cooks!  ($KITCHENLOOP_VERSION)"
echo "==========================================================="
echo "  Base branch: $BASE_BRANCH"
echo "  Mode: $MODE"
echo "  Loops: $MAX_LOOPS"
echo "  Skip: ${SKIP_PHASES:-none}"
echo "  Only: ${ONLY_PHASE:-all phases}"
echo "  Backlog grooming: every $BACKLOG_INTERVAL loops"
echo "  Auto-review: every $REVIEW_INTERVAL iterations"
echo "  Polish max PRs: ${POLISH_MAX_PRS}$([ "$AGGRESSIVE_POLISH" = true ] && echo " (aggressive: $AGGRESSIVE_POLISH_MAX_PRS)")"
echo "  Regress quick: $REGRESS_QUICK"
echo "  Ideate prompt: ${IDEATE_PROMPT}.md"
echo "  Timeouts: ideate=${IDEATE_TIMEOUT}s execute=${EXECUTE_TIMEOUT}s polish=${POLISH_TIMEOUT}s regress=${REGRESS_TIMEOUT}s"
echo "  Drain mode: auto (threshold: $DRAIN_THRESHOLD open PRs, exit: $DRAIN_EXIT_THRESHOLD)"
echo "  Force work: $FORCE_WORK"
echo "  No-work loop limit: $MAX_NO_WORK_LOOPS"
echo "  Worktree isolation: enabled"
if [ "$HAS_CONFIG" = true ]; then
  echo "  Config: $(config_file)"
fi
echo "==========================================================="

CONSECUTIVE_FAILS=0
LAST_ITER_NUM=0
SAME_ITER_COUNT=0
# Load loop counters from persistent state (survive process restarts)
NO_WORK_LOOP_COUNT=$(load_counter "no_work_loop_count" 0)
DRAIN_ENTRY_COUNT=$(load_counter "drain_entry_count" 0)
CONSECUTIVE_STARVED=$(load_counter "consecutive_starved" 0)
STARVATION_MODE=false
if [ "$CONSECUTIVE_STARVED" -gt 0 ] || [ "$NO_WORK_LOOP_COUNT" -gt 0 ] || [ "$DRAIN_ENTRY_COUNT" -gt 0 ]; then
  echo "  Restored counters: starved=$CONSECUTIVE_STARVED, no_work=$NO_WORK_LOOP_COUNT, drain=$DRAIN_ENTRY_COUNT"
fi

# ─── run_iteration ─────────────────────────────────────────────────
run_iteration() {
  local loop="$1"

  git -C "$REPO_ROOT" fetch origin "$BASE_BRANCH" 2>/dev/null || true
  ITER_NUM=$(get_iteration_number "$REPO_ROOT")
  ITER_NUM=$((ITER_NUM + 1))
  echo "  Iteration: $ITER_NUM"

  # ── B2: Stuck-iteration recovery ──
  if [ "$ITER_NUM" -eq "$LAST_ITER_NUM" ]; then
    SAME_ITER_COUNT=$((SAME_ITER_COUNT + 1))
    echo "  [stuck] Same iteration $ITER_NUM detected ($SAME_ITER_COUNT time(s))"
    local stuck_branch="${ITER_BRANCH_PREFIX}-${ITER_NUM}"
    if [ "$SAME_ITER_COUNT" -eq 1 ]; then
      # First retry: try to merge the stuck branch's PR
      echo "  [stuck] Attempting to merge stuck branch PR..."
      local stuck_pr
      stuck_pr=$(gh pr list --head "$stuck_branch" --state open --json number --jq '.[0].number' 2>/dev/null || echo "")
      if [ -n "$stuck_pr" ]; then
        gh pr merge "$stuck_pr" --merge --delete-branch 2>/dev/null || \
          echo "  [stuck] Could not auto-merge PR #$stuck_pr"
      fi
    elif [ "$SAME_ITER_COUNT" -ge 2 ]; then
      # Second+ retry: close abandoned PR, skip to next iteration
      echo "  [stuck] Closing abandoned PR and skipping to iter $((ITER_NUM + 1))..."
      local stuck_pr
      stuck_pr=$(gh pr list --head "$stuck_branch" --state open --json number --jq '.[0].number' 2>/dev/null || echo "")
      if [ -n "$stuck_pr" ]; then
        gh pr close "$stuck_pr" --comment "Closed by KitchenLoop: stuck iteration recovery" 2>/dev/null || true
      fi
      ITER_NUM=$((ITER_NUM + 1))
      SAME_ITER_COUNT=0
      echo "  [stuck] Advanced to iteration $ITER_NUM"
    fi
  else
    SAME_ITER_COUNT=0
  fi
  LAST_ITER_NUM=$ITER_NUM

  # ── B3: Worktree creation with retry ──
  local wt_retries=0
  local wt_max_retries=2
  ITER_WORKTREE=""
  while [ "$wt_retries" -le "$wt_max_retries" ]; do
    if ITER_WORKTREE=$(create_iter_worktree "$ITER_NUM"); then
      break
    fi
    wt_retries=$((wt_retries + 1))
    if [ "$wt_retries" -gt "$wt_max_retries" ]; then
      echo "  ERROR: Could not create worktree for iteration $ITER_NUM after $wt_max_retries retries"
      CONSECUTIVE_FAILS=$((CONSECUTIVE_FAILS + 1))
      if [ "$CONSECUTIVE_FAILS" -ge "$MAX_CONSECUTIVE_FAILS" ]; then
        echo "  Hit $MAX_CONSECUTIVE_FAILS consecutive failures. Stopping."
        exit 1
      fi
      return 1
    fi
    echo "  [worktree] Retry $wt_retries/$wt_max_retries: pruning worktrees and retrying..."
    git -C "$REPO_ROOT" worktree prune >/dev/null 2>&1 || true
    sleep 3
  done

  # Guard: warn if prior iteration has no logs
  local prev_iter=$((ITER_NUM - 1))
  if [ "$prev_iter" -gt 0 ]; then
    local prev_logs
    prev_logs=$(ls "$LOGS_DIR"/loop-"$(printf '%03d' "$prev_iter")"-* 2>/dev/null | wc -l || echo 0)
    if [ "$prev_logs" -eq 0 ]; then
      echo "  [guard] WARNING: No logs found for previous iteration $prev_iter"
    fi
  fi

  echo "  Worktree: $ITER_WORKTREE"

  local iter_had_failure=false

  # ── Backlog grooming (periodic) ──
  if [ "$NO_BACKLOG" = false ] && [ "$BACKLOG_INTERVAL" -gt 0 ]; then
    if (( (loop - 1) % BACKLOG_INTERVAL == 0 )); then
      echo ""
      echo "  --- Backlog Grooming ---"
      if ! run_phase "backlog" "$loop" "backlog" "$ITER_WORKTREE"; then
        echo "  Backlog grooming failed (non-critical), continuing..."
      fi
    fi
  fi

  # ── Pre-ideate: log blocked combos ──
  if ! should_skip "ideate"; then
    local blocked
    blocked=$(get_blocked_combos "$ITER_WORKTREE")
    if [ -n "$blocked" ]; then
      echo ""
      echo "  --- Blocked Combos (injected into ideate prompt) ---"
      echo "$blocked" | while IFS= read -r line; do echo "    $line"; done
    fi
  fi

  # ── Phase 1: Ideate ──
  if ! should_skip "ideate"; then
    echo ""
    echo "  --- Phase 1: Ideate (mode=$MODE) ---"
    if ! run_phase "ideate" "$loop" "$IDEATE_PROMPT" "$ITER_WORKTREE"; then
      echo "  Ideate failed, continuing to next phase..."
      iter_had_failure=true
    fi
    check_iter_artifacts "$ITER_WORKTREE" || true
    local ideate_log="$LOGS_DIR/loop-$(printf '%03d' "$loop")-ideate.log"
    commit_iter_artifacts "$ITER_WORKTREE" "$ITER_NUM" "ideate" 2>&1 | tee -a "$ideate_log"
    # Validate coverage matrix wasn't corrupted in the worktree
    local cov_relative
    cov_relative=$(config_get_default "paths.coverage_matrix" ".kitchenloop/coverage-matrix.yaml" 2>/dev/null || echo ".kitchenloop/coverage-matrix.yaml")
    local cov_wt="$ITER_WORKTREE/$cov_relative"
    if [ -f "$cov_wt" ] && ! yq '.' "$cov_wt" >/dev/null 2>&1; then
      echo "  [integrity] WARNING: coverage-matrix.yaml is not valid YAML after ideate"
      echo "$(date) | Iter $ITER_NUM | integrity | coverage-matrix YAML invalid" >> "$LOG_FILE"
    fi
    persist_reports_to_main "$ITER_WORKTREE" "$ITER_NUM"
    if [ "$MODE" = "ui" ]; then
      persist_ui_state_to_main "$ITER_WORKTREE" "$ITER_NUM"
    fi
  fi

  # ── Phase 2: Triage ──
  if ! should_skip "triage"; then
    echo ""
    echo "  --- Phase 2: Triage ---"
    run_phase_hook "triage" "preflight" "$loop" "$ITER_WORKTREE"
    if ! run_phase "triage" "$loop" "triage" "$ITER_WORKTREE"; then
      echo "  Triage failed, continuing to next phase..."
      iter_had_failure=true
    fi
    run_phase_hook "triage" "dedup-sweep" "$loop" "$ITER_WORKTREE"
    if [ "$MODE" = "ui" ]; then
      run_phase_hook "triage" "bug-reproduce" "$loop" "$ITER_WORKTREE"
    fi
  fi

  # ── Phase 3: Execute ──
  EXECUTE_FAILED=false
  EXECUTE_PRODUCED_WORK=false
  EXECUTE_SKIPPED_BACKPRESSURE=false
  if ! should_skip "execute"; then
    # B4: Shell-level backpressure check before execute
    if [ "$FORCE_WORK" = false ] && command -v gh >/dev/null 2>&1; then
      local exec_open_prs
      exec_open_prs=$(gh pr list --base "$BASE_BRANCH" --state open --json number --jq 'length' 2>/dev/null || echo 0)
      if [ "$exec_open_prs" -gt "$DRAIN_THRESHOLD" ]; then
        echo ""
        echo "  --- Phase 3: Execute (SKIPPED -- $exec_open_prs open PRs > $DRAIN_THRESHOLD threshold) ---"
        echo "  [execute] Backpressure too high, skipping execute to save compute"
        echo "$(date) | Iter $ITER_NUM | execute | SKIPPED (backpressure: $exec_open_prs open PRs)" >> "$LOG_FILE"
        EXECUTE_SKIPPED_BACKPRESSURE=true
      fi
    fi

    if [ "$EXECUTE_SKIPPED_BACKPRESSURE" = false ]; then
      echo ""
      echo "  --- Phase 3: Execute ---"

      # C3: Starvation escalation — two tiers:
      #   Tier 1: Tell execute to fall back to backlog
      #   Tier 2: Skip execute entirely, only run backlog grooming
      if [ "$CONSECUTIVE_STARVED" -ge "$STARVE_SKIP_EXECUTE_THRESHOLD" ]; then
        echo "  [execute] SKIPPED: $CONSECUTIVE_STARVED consecutive starved iterations (threshold: $STARVE_SKIP_EXECUTE_THRESHOLD)"
        echo "  [execute] Auto-skipping execute — only backlog grooming can help at this point"
        echo "$(date) | Iter $ITER_NUM | execute auto-skipped after $CONSECUTIVE_STARVED starved iterations" \
          >> "$PERSISTENT_STATE_DIR/starvation_skip.log"
        EXECUTE_SKIPPED_BACKPRESSURE=true  # reuse flag to skip execute
      elif [ "$CONSECUTIVE_STARVED" -ge "$STARVE_BACKLOG_THRESHOLD" ]; then
        STARVATION_MODE=true
        echo "  [execute] STARVATION MODE: $CONSECUTIVE_STARVED consecutive starved iterations, falling back to backlog"
      fi

      # B1: Record pre-execute state (worktree HEAD + open PR count)
      local pre_execute_head pre_execute_prs
      pre_execute_head=$(git -C "$ITER_WORKTREE" rev-parse HEAD 2>/dev/null || echo "")
      pre_execute_prs=$(gh pr list --base "$BASE_BRANCH" --state open --json number \
        --jq 'length' 2>/dev/null || echo 0)

      if ! run_phase "execute" "$loop" "execute" "$ITER_WORKTREE"; then
        EXECUTE_FAILED=true
        echo "  Execute failed, continuing to next phase..."
        iter_had_failure=true
      fi

      # B1: Detect if execute produced any work — check both worktree commits AND new PRs
      # Execute creates PRs on separate branches (worktree HEAD may not change)
      local post_execute_head post_execute_prs
      post_execute_head=$(git -C "$ITER_WORKTREE" rev-parse HEAD 2>/dev/null || echo "")
      post_execute_prs=$(gh pr list --base "$BASE_BRANCH" --state open --json number \
        --jq 'length' 2>/dev/null || echo 0)
      local new_pr_count=$(( post_execute_prs - pre_execute_prs ))
      if [ -n "$pre_execute_head" ] && [ "$pre_execute_head" != "$post_execute_head" ]; then
        local commit_count
        commit_count=$(git -C "$ITER_WORKTREE" rev-list --count "${pre_execute_head}..HEAD" 2>/dev/null || echo 0)
        EXECUTE_PRODUCED_WORK=true
        CONSECUTIVE_STARVED=0
        persist_counter "consecutive_starved" 0
        STARVATION_MODE=false
        echo "  [execute] Produced $commit_count commit(s)"
      elif [ "$new_pr_count" -gt 0 ]; then
        # Execute created PRs on separate branches — count as work
        EXECUTE_PRODUCED_WORK=true
        CONSECUTIVE_STARVED=0
        persist_counter "consecutive_starved" 0
        STARVATION_MODE=false
        echo "  [execute] Produced $new_pr_count new PR(s) (on feature branches)"
      else
        echo "  [execute] No new commits or PRs produced"
        CONSECUTIVE_STARVED=$((CONSECUTIVE_STARVED + 1))
        persist_counter "consecutive_starved" "$CONSECUTIVE_STARVED"
      fi
    fi
  fi

  # ── UAT Gate (post-execute) ──
  local UAT_GATE_FAILED=false
  if [ "$EXECUTE_PRODUCED_WORK" = true ] && [ "$EXECUTE_FAILED" != true ]; then
    if ! check_uat_verdicts "$ITER_WORKTREE"; then
      UAT_GATE_FAILED=true
      echo "  [uat-gate] BLOCKED — UAT failures detected. Merge will be blocked."
      echo "$(date) | Iter $ITER_NUM | uat-gate | BLOCKED" >> "$LOG_FILE"
    fi
  fi

  # ── Phase 3.5: Polish ──
  if ! should_skip "polish"; then
    echo ""
    echo "  --- Phase 3.5: Polish ---"

    # Pre-polish cleanup
    echo "  [polish] Reclaiming memory: killing orphaned subagent processes..."
    pkill -f 'claude.*--print.*kitchenloop' 2>/dev/null || true
    sleep 2

    polish_timeout=$(get_timeout "polish")
    polish_log="$LOGS_DIR/loop-$(printf '%03d' "${ITER_NUM:-$loop}")-polish.log"
    echo ""
    echo "  [polish] Starting (timeout: ${polish_timeout}s)"
    echo "  [polish] Live log: tail -f $polish_log"
    echo "  $(date '+%H:%M:%S') ──────────────────────────────"

    polish_exit=0
    polish_timed_out=false

    polish_max_prs="$POLISH_MAX_PRS"
    if [ "$AGGRESSIVE_POLISH" = true ]; then
      polish_max_prs=$AGGRESSIVE_POLISH_MAX_PRS
    fi
    echo "  [polish] Processing up to $polish_max_prs PRs this iteration"

    local per_pr_timeout=$(( polish_timeout / (polish_max_prs + 1) ))
    # Enforce minimum per-PR timeout floor (30 min) — if the floor would be
    # violated, reduce the number of PR slots instead of making each unusably small
    local pr_timeout_floor=1800
    if [ "$per_pr_timeout" -lt "$pr_timeout_floor" ]; then
      per_pr_timeout="$pr_timeout_floor"
      polish_max_prs=$(( polish_timeout / pr_timeout_floor - 1 ))
      [ "$polish_max_prs" -lt 1 ] && polish_max_prs=1
      echo "  [polish] Timeout floor enforced: reduced to $polish_max_prs PRs at ${per_pr_timeout}s each"
    fi
    local pr_manager_script="$REPO_ROOT/scripts/pr-manager/pr-manager.sh"
    if [ -x "$pr_manager_script" ]; then
      # Always run from REPO_ROOT — polish operates on GitHub PRs, not local code.
      # Running from ITER_WORKTREE causes the worktree to be deleted mid-polish
      # (Claude's git operations inside the worktree corrupt/remove it).
      local polish_cwd="$REPO_ROOT"
      (cd "$polish_cwd" && BASE_BRANCH="$BASE_BRANCH" "$pr_manager_script" \
        --max-prs "$polish_max_prs" --once --no-parallel \
        --budget "$polish_timeout" --timeout "$per_pr_timeout" --max-turns 80) \
        > "$polish_log" 2>&1 &
      polish_pid=$!

      # Watchdog: kill process group on timeout (macOS zombie fix)
      (
        sleep "$polish_timeout"
        touch "${polish_log}.timeout"
        local pgid
        pgid=$(ps -o pgid= -p "$polish_pid" 2>/dev/null | tr -d ' ')
        [ -n "$pgid" ] && kill -- -"$pgid" 2>/dev/null || kill "$polish_pid" 2>/dev/null || true
        sleep 10
        pgid=$(ps -o pgid= -p "$polish_pid" 2>/dev/null | tr -d ' ')
        [ -n "$pgid" ] && kill -9 -- -"$pgid" 2>/dev/null || kill -9 "$polish_pid" 2>/dev/null || true
      ) &
      polish_watchdog=$!

      wait "$polish_pid" 2>/dev/null || polish_exit=$?
      kill "$polish_watchdog" 2>/dev/null || true; wait "$polish_watchdog" 2>/dev/null 2>&1 || true

      if [ -f "${polish_log}.timeout" ]; then
        polish_timed_out=true
        rm -f "${polish_log}.timeout"
      fi
    else
      echo "  [polish] pr-manager.sh not found, skipping"
      echo "SKIPPED: pr-manager.sh not found" > "$polish_log"
    fi

    if [ "$polish_timed_out" = true ]; then
      echo "  [polish] TIMEOUT after ${polish_timeout}s  (log: $polish_log)"
      echo "$(date) | Loop $loop | polish | mode=$MODE | TIMEOUT (${polish_timeout}s) | $polish_log" >> "$LOG_FILE"
    elif [ "$polish_exit" -ne 0 ]; then
      echo "  [polish] FAILED (exit code $polish_exit)  (log: $polish_log)"
      echo "$(date) | Loop $loop | polish | mode=$MODE | FAILED (exit $polish_exit) | $polish_log" >> "$LOG_FILE"
      if [ "$polish_exit" -eq 137 ] || [ "$polish_exit" -eq 143 ]; then
        echo "  [polish] Process killed (exit $polish_exit, likely OOM). Retrying with reduced scope..."
        # Kill any orphaned processes
        pkill -f 'claude.*--print.*pr-manager' 2>/dev/null || true
        sleep 5
        local retry_log="${polish_log%.log}-retry.log"
        if [ -x "$pr_manager_script" ]; then
          echo "  [polish] Retry: --max-prs 1 --max-turns 40"
          (cd "$ITER_WORKTREE" && BASE_BRANCH="$BASE_BRANCH" "$pr_manager_script" \
            --max-prs 1 --once --no-parallel \
            --budget "$polish_timeout" --timeout "$per_pr_timeout" --max-turns 40) \
            > "$retry_log" 2>&1 || true
          local retry_merged
          retry_merged=$(grep -oE 'Merged: [0-9]+' "$retry_log" 2>/dev/null | tail -1 | grep -oE '[0-9]+' || echo 0)
          echo "  [polish] Retry merged $retry_merged PR(s)"
          echo "$(date) | Loop $loop | polish | OOM RETRY | merged=$retry_merged | $retry_log" >> "$LOG_FILE"
        fi
        iter_had_failure=true
      fi
    else
      echo "  [polish] DONE  (log: $polish_log)"
      echo "$(date) | Loop $loop | polish | mode=$MODE | OK | $polish_log" >> "$LOG_FILE"
    fi

    # Extract merged count from polish log for drain-mode circuit breaker
    LAST_POLISH_MERGED=$(grep -oE 'Merged: [0-9]+' "$polish_log" 2>/dev/null | tail -1 | grep -oE '[0-9]+' || echo 0)
    echo "  [polish] Merged $LAST_POLISH_MERGED PRs this loop"
  fi

  # ── Sync worktree with merged PRs before regress ──
  sync_iter_worktree "$ITER_WORKTREE"

  # ── Phase 4: Regress ──
  if ! should_skip "regress" && { [ "$EXECUTE_FAILED" = true ] || [ "$EXECUTE_PRODUCED_WORK" = false ]; }; then
    echo ""
    echo "  --- Phase 4: Regress (SKIPPED -- no work to regress) ---"
  elif ! should_skip "regress"; then
    echo ""
    echo "  --- Phase 4: Regress ---"
    if ! run_phase "regress" "$loop" "regress" "$ITER_WORKTREE"; then
      echo "  Regress failed."
      iter_had_failure=true
    fi
  fi

  # ── Shell-enforced regression gate ──
  # Safety: run the actual test command here in the shell layer, independent of
  # whatever Claude did during the regress phase. This is the hard merge gate.
  #
  # IMPORTANT: The gate tests main (REPO_ROOT), NOT the iteration worktree.
  # The worktree contains partial work (unmerged PRs from execute), so testing it
  # answers the wrong question. The correct question is: "Is main still healthy
  # after the polish phase merged PRs?" (See whitepaper Section 7.2)
  local regress_log="$LOGS_DIR/loop-$(printf '%03d' "$loop")-regress.log"
  local regress_passed=true

  if ! should_skip "regress" && [ "$EXECUTE_FAILED" != true ]; then
    local shell_test_cmd="${FULL_TEST_CMD}"
    if [ "$REGRESS_QUICK" = true ]; then
      shell_test_cmd="${QUICK_TEST_CMD}"
    fi
    echo ""

    # Always test main — pull latest merged changes first
    local regress_dir="$REPO_ROOT"
    git -C "$REPO_ROOT" pull --ff-only origin "$BASE_BRANCH" 2>/dev/null || true
    echo "  [regress-gate] Testing $BASE_BRANCH at $REPO_ROOT (post-merge state)"
    echo "  [regress-gate] Running shell-enforced regression: $shell_test_cmd"
    if ! (cd "$regress_dir" && eval "$shell_test_cmd") >> "$regress_log" 2>&1; then
      echo "  [regress-gate] FAILED — $BASE_BRANCH has test failures after merge."
      echo "$(date) | Iter $ITER_NUM | regress-gate | FAILED — $BASE_BRANCH broken" >> "$LOG_FILE"
      regress_passed=false
      iter_had_failure=true
    else
      echo "  [regress-gate] PASSED — $BASE_BRANCH is healthy."
      echo "$(date) | Iter $ITER_NUM | regress-gate | PASSED" >> "$LOG_FILE"
    fi

    # Also run L3 smoke test if configured
    if [ -n "${SMOKE_CMD}" ]; then
      echo "  [regress-gate] Running L3 smoke test: $SMOKE_CMD"
      if ! (cd "$regress_dir" && eval "$SMOKE_CMD") >> "$regress_log" 2>&1; then
        echo "  [regress-gate] L3 SMOKE FAILED — product may be broken despite passing unit tests."
        echo "$(date) | Iter $ITER_NUM | regress-gate | L3 SMOKE FAILED" >> "$LOG_FILE"
        regress_passed=false
        iter_had_failure=true
      else
        echo "  [regress-gate] L3 smoke PASSED."
      fi
    fi
  fi

  # ── Canary check (optional, advisory — warns but does not halt) ──
  if [ -n "$CANARY_CHECK_CMD" ]; then
    echo "  [canary] Running: $CANARY_CHECK_CMD $ITER_NUM"
    if ! "$CANARY_CHECK_CMD" "$ITER_NUM" >> "$regress_log" 2>&1; then
      echo "  [canary] WARNING — canary check failed (advisory, loop continues)"
      echo "$(date) | Iter $ITER_NUM | canary | WARNING" >> "$LOG_FILE"
    else
      echo "  [canary] PASSED"
    fi
  fi

  # ── Record iteration metrics for drift tracking ──
  if ! should_skip "regress" && [ "$EXECUTE_FAILED" != true ]; then
    record_iteration_metrics "$ITER_NUM" "$regress_log"
    if ! check_drift_thresholds; then
      DRIFT_WARNING=true
      echo "$(date) | Iter $ITER_NUM | drift | WARNING — quality metrics declining" >> "$LOG_FILE"
    fi
  fi

  # ── Commit regress artifacts and merge back (only if regression passed) ──
  commit_iter_artifacts "$ITER_WORKTREE" "$ITER_NUM" "regress" 2>&1 | tee -a "$regress_log"

  # B5: Always fetch before sync to ensure counter bump happens regardless of merge outcome
  git -C "$REPO_ROOT" fetch origin "$BASE_BRANCH" 2>/dev/null || true

  # ── Sync loop-state directly to $BASE_BRANCH (decoupled from worktree merge) ──
  sync_loop_state_to_base "$ITER_WORKTREE" "$ITER_NUM"

  local merge_ok=true
  local verify_ok=true

  if [ "$regress_passed" = true ] && [ "${UAT_GATE_FAILED:-false}" != true ]; then
    merge_iter_back "$ITER_WORKTREE" "$ITER_NUM" || merge_ok=false
    verify_merge "$ITER_NUM" || verify_ok=false
  elif [ "${UAT_GATE_FAILED:-false}" = true ]; then
    echo "  [merge] SKIPPED — UAT gate failed. Will not merge iteration $ITER_NUM."
    echo "$(date) | Iter $ITER_NUM | merge | BLOCKED by uat-gate" >> "$LOG_FILE"
    merge_ok=false
  else
    echo "  [merge] SKIPPED — regression gate failed. Will not merge iteration $ITER_NUM."
    echo "$(date) | Iter $ITER_NUM | merge | BLOCKED by regress-gate" >> "$LOG_FILE"
    merge_ok=false
    verify_ok=false
  fi

  # ── Post-merge snapshot (UI mode) ──
  if [ "$merge_ok" = true ] && [ "$MODE" = "ui" ]; then
    local snapshot_script="$REPO_ROOT/scripts/post-iteration-snapshot.sh"
    if [ -x "$snapshot_script" ]; then
      echo "  [snapshot] Taking post-merge app screenshot for iteration $ITER_NUM..."
      ("$snapshot_script" "$ITER_NUM") 2>&1 | grep "\[snapshot\]" || true
    fi
  fi

  # ── Auto-review every N iterations ──
  if [ "$REVIEW_INTERVAL" -gt 0 ] && (( loop % REVIEW_INTERVAL == 0 )); then
    review_start=$((ITER_NUM - REVIEW_INTERVAL + 1))
    run_auto_review "$review_start" "$ITER_NUM"
    commit_iter_artifacts "$ITER_WORKTREE" "$ITER_NUM" "review"
  fi

  # ── Cleanup ──
  if [ "$verify_ok" = true ]; then
    cleanup_iter_worktree "$ITER_WORKTREE" "$ITER_NUM"
  else
    echo "  [cleanup] SKIPPING worktree cleanup -- artifacts missing from ${BASE_BRANCH}"
    echo "  [cleanup] Preserved: $ITER_WORKTREE"
    echo "$(date) | Iter $ITER_NUM | cleanup | SKIPPED -- artifacts missing" >> "$LOG_FILE"
  fi

  clean_agent_junk "$REPO_ROOT"

  if [ "$iter_had_failure" = true ]; then
    return 1
  fi
  return 0
}

for loop in $(seq 1 "$MAX_LOOPS"); do
  echo ""
  echo "==========================================================="
  echo "  LOOP $loop of $MAX_LOOPS"
  echo "  $(date)"
  echo "==========================================================="

  # ── Drain mode: auto-trigger when PR backpressure is too high ──
  # Save original values so drain mode doesn't permanently override
  ORIG_SKIP_PHASES="$SKIP_PHASES"
  ORIG_POLISH_MAX_PRS="$POLISH_MAX_PRS"
  ORIG_ONLY_PHASE="$ONLY_PHASE"
  LAST_POLISH_MERGED=${LAST_POLISH_MERGED:-0}  # reset per-loop; set by polish phase if it runs

  OPEN_PRS=-1
  if command -v gh >/dev/null 2>&1; then
    OPEN_PRS=$(gh pr list --base "$BASE_BRANCH" --state open --json number \
      --jq 'length' 2>/dev/null) || OPEN_PRS=-1
  fi

  if { [ "$OPEN_PRS" -ge 0 ] && [ "$OPEN_PRS" -gt "$DRAIN_THRESHOLD" ]; } || [ "$DRAIN_MODE" = true ]; then
    if [ "$DRAIN_MODE" = false ]; then
      echo "  [drain] ENTERING drain mode: $OPEN_PRS open PRs > $DRAIN_THRESHOLD threshold"
      echo "$(date) | Loop $loop | DRAIN MODE ENTERED ($OPEN_PRS open PRs)" >> "$LOG_FILE"
      DRAIN_MODE=true
      DRAIN_ZERO_MERGE_COUNT=0
    fi

    if [ "$OPEN_PRS" -ge 0 ] && [ "$OPEN_PRS" -lt "$DRAIN_EXIT_THRESHOLD" ]; then
      echo "  [drain] EXITING drain mode: $OPEN_PRS open PRs < $DRAIN_EXIT_THRESHOLD"
      echo "$(date) | Loop $loop | DRAIN MODE EXITED ($OPEN_PRS open PRs)" >> "$LOG_FILE"
      DRAIN_MODE=false
      DRAIN_ZERO_MERGE_COUNT=0
    else
      echo "  [drain] Drain mode active ($OPEN_PRS open PRs). Running polish-only with max 4 PRs."
      ONLY_PHASE="polish"
      SKIP_PHASES="backlog,ideate,triage,execute,regress"
      POLISH_MAX_PRS=4
    fi
  fi

  # Initialize per-iteration state so main-loop checks are safe even if
  # run_iteration returns early (e.g. worktree creation failure)
  EXECUTE_PRODUCED_WORK=false
  EXECUTE_SKIPPED_BACKPRESSURE=false
  EXECUTE_FAILED=false

  if run_iteration "$loop"; then
    CONSECUTIVE_FAILS=0
    echo ""
    echo "  Loop $loop complete."
    echo "$(date) | Loop $loop | LOOP COMPLETE" >> "$LOG_FILE"
  else
    CONSECUTIVE_FAILS=$((CONSECUTIVE_FAILS + 1))
    echo ""
    echo "  Loop $loop FAILED (consecutive failures: $CONSECUTIVE_FAILS/$MAX_CONSECUTIVE_FAILS)"
    echo "$(date) | Loop $loop | LOOP FAILED ($CONSECUTIVE_FAILS consecutive)" >> "$LOG_FILE"

    if [ "$CONSECUTIVE_FAILS" -ge "$MAX_CONSECUTIVE_FAILS" ]; then
      echo "  Hit $MAX_CONSECUTIVE_FAILS consecutive iteration failures. Stopping."
      echo "$(date) | STOPPED after $MAX_CONSECUTIVE_FAILS consecutive failures" >> "$LOG_FILE"
      exit 1
    fi
    echo "  Moving on to next iteration..."
  fi

  # ── Drain mode circuit breaker: stop if polish keeps merging 0 PRs ──
  if [ "$DRAIN_MODE" = true ]; then
    if [ "${LAST_POLISH_MERGED:-0}" -eq 0 ]; then
      DRAIN_ZERO_MERGE_COUNT=$((DRAIN_ZERO_MERGE_COUNT + 1))
      echo "  [drain] Zero merges this loop ($DRAIN_ZERO_MERGE_COUNT/$MAX_DRAIN_ZERO_MERGES consecutive)"
      if [ "$DRAIN_ZERO_MERGE_COUNT" -gt "$MAX_DRAIN_ZERO_MERGES" ]; then
        echo "  [drain] CIRCUIT BREAKER: $MAX_DRAIN_ZERO_MERGES consecutive loops with 0 merges."
        echo "  [drain] Exiting drain mode to resume normal iterations. PRs need manual attention."
        echo "$(date) | Loop $loop | DRAIN CIRCUIT BREAKER ($DRAIN_ZERO_MERGE_COUNT zero-merge loops)" >> "$LOG_FILE"
        DRAIN_MODE=false
        DRAIN_ZERO_MERGE_COUNT=0
      fi
    else
      DRAIN_ZERO_MERGE_COUNT=0
    fi
  fi

  # ── C1: No-work infinite loop breaker ──
  if [ "$EXECUTE_PRODUCED_WORK" = false ] && [ "$EXECUTE_SKIPPED_BACKPRESSURE" = false ] && [ "$EXECUTE_FAILED" = false ]; then
    NO_WORK_LOOP_COUNT=$((NO_WORK_LOOP_COUNT + 1))
    persist_counter "no_work_loop_count" "$NO_WORK_LOOP_COUNT"
    echo "  [no-work] No work produced ($NO_WORK_LOOP_COUNT/$MAX_NO_WORK_LOOPS consecutive)"
    if [ "$NO_WORK_LOOP_COUNT" -ge "$MAX_NO_WORK_LOOPS" ]; then
      echo "  [no-work] Switching to polish-only mode to drain backlog"
      DRAIN_ENTRY_COUNT=$((DRAIN_ENTRY_COUNT + 1))
      persist_counter "drain_entry_count" "$DRAIN_ENTRY_COUNT"
      if [ "$DRAIN_ENTRY_COUNT" -gt "$MAX_DRAIN_ENTRIES" ]; then
        echo "  [no-work] HARD STOP: $DRAIN_ENTRY_COUNT drain entries with no work. Nothing left to do."
        echo "$(date) | Loop $loop | HARD STOP: no-work loop limit reached" >> "$LOG_FILE"
        break
      fi
      NO_WORK_LOOP_COUNT=0
      persist_counter "no_work_loop_count" 0
    fi
  else
    NO_WORK_LOOP_COUNT=0
    persist_counter "no_work_loop_count" 0
    DRAIN_ENTRY_COUNT=0
    persist_counter "drain_entry_count" 0
  fi

  # ── C7: Force ideate every N iterations even when stale ──
  if [ "$FORCE_IDEATE_INTERVAL" -gt 0 ] && (( loop % FORCE_IDEATE_INTERVAL == 0 )); then
    if echo ",$SKIP_PHASES," | grep -q ",ideate,"; then
      echo "  [circuit-breaker] Forcing ideate (every $FORCE_IDEATE_INTERVAL iterations)"
      SKIP_PHASES=$(echo "$SKIP_PHASES" | sed 's/ideate//g; s/,,/,/g; s/^,//; s/,$//')
    fi
  fi

  # ── C7: Ticket drought override ──
  if [ "$CONSECUTIVE_STARVED" -ge "$TICKET_DROUGHT_THRESHOLD" ]; then
    echo "  [circuit-breaker] Ticket drought ($CONSECUTIVE_STARVED starved iterations). Forcing backlog grooming next loop."
    NO_BACKLOG=false
    BACKLOG_INTERVAL=1
  fi

  # Restore original phase config (drain mode may have overridden)
  SKIP_PHASES="$ORIG_SKIP_PHASES"
  POLISH_MAX_PRS="$ORIG_POLISH_MAX_PRS"
  ONLY_PHASE="$ORIG_ONLY_PHASE"

  sleep 5
done

echo ""
echo "==========================================================="
echo "  Kitchen Loop finished $MAX_LOOPS loops"
echo "  Summary log: $LOG_FILE"
echo "  Phase logs:  $LOGS_DIR/"
echo "==========================================================="
