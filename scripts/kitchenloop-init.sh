#!/bin/bash
# kitchenloop-init.sh — Interactive scaffold wizard
#
# Sets up KitchenLoop in any git repository. Creates config, copies scripts,
# installs skills, and creates initial artifact directories.
#
# Usage:
#   cd /path/to/your/repo
#   /path/to/kitchenloop/scripts/kitchenloop-init.sh
#
#   # Or with env var:
#   KITCHENLOOP_HOME=/path/to/kitchenloop kitchenloop-init.sh

set -euo pipefail

# ─── Resolve KitchenLoop home directory ──────────────────────────────────
if [ -n "${KITCHENLOOP_HOME:-}" ]; then
  KL_HOME="$KITCHENLOOP_HOME"
else
  KL_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

if [ ! -f "$KL_HOME/kitchenloop.example.yaml" ]; then
  echo "ERROR: Cannot find KitchenLoop home directory."
  echo "  Set KITCHENLOOP_HOME or run from the kitchenloop repo."
  exit 1
fi

# ─── Prerequisites check ────────────────────────────────────────────────
echo "Checking prerequisites..."
MISSING=()
for cmd in claude git gh jq yq; do
  if ! command -v "$cmd" &>/dev/null; then
    MISSING+=("$cmd")
  fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
  echo ""
  echo "ERROR: Missing required tools: ${MISSING[*]}"
  echo ""
  echo "Install them:"
  for cmd in "${MISSING[@]}"; do
    case "$cmd" in
      claude) echo "  claude: npm install -g @anthropic-ai/claude-code" ;;
      git)    echo "  git:    brew install git  (or: apt install git)" ;;
      gh)     echo "  gh:     brew install gh   (or: apt install gh)" ;;
      jq)     echo "  jq:     brew install jq   (or: apt install jq)" ;;
      yq)     echo "  yq:     brew install yq   (or: go install github.com/mikefarah/yq/v4@latest)" ;;
    esac
  done
  exit 1
fi
echo "  All prerequisites found."

# ─── Verify we're in a git repo ──────────────────────────────────────────
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  echo ""
  echo "ERROR: Not inside a git repository."
  echo "  cd into your project repo first, then run this script."
  exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
echo "  Repo root: $REPO_ROOT"

# ─── Check if already initialized ───────────────────────────────────────
if [ -f "$REPO_ROOT/kitchenloop.yaml" ]; then
  echo ""
  echo "WARNING: kitchenloop.yaml already exists in $REPO_ROOT"
  read -rp "  Overwrite? (y/N) " answer
  if [[ ! "$answer" =~ ^[Yy] ]]; then
    echo "  Aborted."
    exit 0
  fi
fi

# ─── Interactive setup ──────────────────────────────────────────────────
echo ""
echo "==========================================================="
echo "  KitchenLoop — the Loop that Cooks!"
echo "  Interactive Setup"
echo "==========================================================="
echo ""

# Detect defaults from repo
DEFAULT_NAME=$(basename "$REPO_ROOT")
DEFAULT_BRANCH=$(git -C "$REPO_ROOT" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo "main")
DEFAULT_REMOTE=$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || echo "")

# Detect language
DEFAULT_LANG="unknown"
if [ -f "$REPO_ROOT/pyproject.toml" ] || [ -f "$REPO_ROOT/setup.py" ]; then
  DEFAULT_LANG="python"
elif [ -f "$REPO_ROOT/package.json" ]; then
  DEFAULT_LANG="typescript"
elif [ -f "$REPO_ROOT/go.mod" ]; then
  DEFAULT_LANG="go"
elif [ -f "$REPO_ROOT/Cargo.toml" ]; then
  DEFAULT_LANG="rust"
fi

# Detect test/lint commands
DEFAULT_TEST="make test"
DEFAULT_LINT="make lint"
if [ -f "$REPO_ROOT/Makefile" ]; then
  if grep -q '^test:' "$REPO_ROOT/Makefile"; then
    DEFAULT_TEST="make test"
  fi
  if grep -q '^lint:' "$REPO_ROOT/Makefile"; then
    DEFAULT_LINT="make lint"
  fi
elif [ -f "$REPO_ROOT/package.json" ]; then
  DEFAULT_TEST="npm test"
  DEFAULT_LINT="npm run lint"
elif [ -f "$REPO_ROOT/pyproject.toml" ]; then
  DEFAULT_TEST="pytest"
  DEFAULT_LINT="ruff check ."
fi

# Ask questions
read -rp "Project name [$DEFAULT_NAME]: " PROJECT_NAME
PROJECT_NAME="${PROJECT_NAME:-$DEFAULT_NAME}"

read -rp "One-line description: " PROJECT_DESC

read -rp "Language [$DEFAULT_LANG]: " PROJECT_LANG
PROJECT_LANG="${PROJECT_LANG:-$DEFAULT_LANG}"

read -rp "Base branch [$DEFAULT_BRANCH]: " BASE_BRANCH
BASE_BRANCH="${BASE_BRANCH:-$DEFAULT_BRANCH}"

read -rp "Test command [$DEFAULT_TEST]: " TEST_CMD
TEST_CMD="${TEST_CMD:-$DEFAULT_TEST}"

read -rp "Quick test command (unit tests) [$DEFAULT_TEST]: " QUICK_TEST_CMD
QUICK_TEST_CMD="${QUICK_TEST_CMD:-$TEST_CMD}"

read -rp "Lint command [$DEFAULT_LINT]: " LINT_CMD
LINT_CMD="${LINT_CMD:-$DEFAULT_LINT}"

echo ""
echo "─── Unbeatable Tests (L3 Integration) ───"
echo "An L3 smoke test starts your REAL app and hits REAL endpoints."
echo "This is the gate that catches '38 passing unit tests, broken service'."
echo "Examples:"
echo "  Web app:  npm run test:smoke    (starts server, curls health endpoint)"
echo "  CLI:      bash tests/smoke.sh   (runs real CLI, checks output)"
echo "  API:      pytest tests/smoke/   (hits real API, checks responses)"
echo ""
read -rp "L3 smoke test command (leave empty to bootstrap later): " SMOKE_CMD
SMOKE_CMD="${SMOKE_CMD:-}"

echo ""
echo "Ticketing provider:"
echo "  1) github  — GitHub Issues with label-based state tracking"
echo "  2) linear  — Linear (requires MCP integration)"
echo "  3) none    — Local JSON file (no external service)"
read -rp "Choice [1]: " TICKET_CHOICE
case "${TICKET_CHOICE:-1}" in
  1) TICKET_PROVIDER="github" ;;
  2) TICKET_PROVIDER="linear" ;;
  3) TICKET_PROVIDER="none" ;;
  *) TICKET_PROVIDER="github" ;;
esac

echo ""
echo "─── Project Context (for the AI synthetic user) ───"
echo "This tells the loop HOW a real user interacts with your project."
echo "The better this is, the better the loop's ideation will be."
echo ""
read -rp "How do users interact with this project? (CLI/API/UI/library): " INTERACTION_TYPE
INTERACTION_TYPE="${INTERACTION_TYPE:-CLI}"

echo ""
echo "Describe a typical user session (2-5 steps). Press Enter twice when done:"
USER_SESSION=""
while IFS= read -r line; do
  [ -z "$line" ] && break
  USER_SESSION="${USER_SESSION}    ${line}\n"
done

echo ""
read -rp "What does 'success' look like for a user? " SUCCESS_CRITERIA
SUCCESS_CRITERIA="${SUCCESS_CRITERIA:-The user can complete their task without confusion or errors.}"

# Build project context YAML block
PROJECT_CONTEXT="  context: |\n"
PROJECT_CONTEXT="${PROJECT_CONTEXT}    ${PROJECT_NAME} is a ${PROJECT_LANG} project (${INTERACTION_TYPE}).\n"
PROJECT_CONTEXT="${PROJECT_CONTEXT}    ${PROJECT_DESC}\n"
PROJECT_CONTEXT="${PROJECT_CONTEXT}\n"
PROJECT_CONTEXT="${PROJECT_CONTEXT}    A typical user session:\n"
PROJECT_CONTEXT="${PROJECT_CONTEXT}${USER_SESSION}\n"
PROJECT_CONTEXT="${PROJECT_CONTEXT}    Success = ${SUCCESS_CRITERIA}\n"

echo ""
echo "Spec surface dimensions (comma-separated):"
read -rp "  Features to exercise [auth,api,ui]: " FEATURES_RAW
FEATURES_RAW="${FEATURES_RAW:-auth,api,ui}"
# Convert to YAML list
FEATURES_YAML=""
IFS=',' read -ra FEAT_ARRAY <<< "$FEATURES_RAW"
for f in "${FEAT_ARRAY[@]}"; do
  f=$(echo "$f" | xargs)  # trim whitespace
  FEATURES_YAML="${FEATURES_YAML}    - \"$f\"\n"
done

# ─── Generate kitchenloop.yaml ──────────────────────────────────────────
echo ""
echo "Generating kitchenloop.yaml..."

cat > "$REPO_ROOT/kitchenloop.yaml" << YAML_EOF
# ─── KitchenLoop Configuration ───────────────────────────────────────────
# Generated by kitchenloop init on $(date -u +%Y-%m-%dT%H:%M:%SZ)

project:
  name: "$PROJECT_NAME"
  description: "$PROJECT_DESC"
  language: "$PROJECT_LANG"
$(echo -e "$PROJECT_CONTEXT")

repo:
  base_branch: "$BASE_BRANCH"
  pr_target: "$BASE_BRANCH"
  iteration_branch_prefix: "kitchen/iter"
  env_file: ".env"

paths:
  reports: "docs/internal/reports"
  loop_state: "docs/internal/loop-state.md"
  patterns: "memory/codebase-patterns.md"
  logs: ".kitchenloop/logs"
  scenarios: "scenarios/incubating"
  worktree_prefix: ".claude/worktrees"
  execute_worktree: ".claude/worktrees/kitchenloop"
  uat_cards: ".kitchenloop/uat-cards"
  uat_runs: ".kitchenloop/uat-runs"
  unbeatable_tests: ".kitchenloop/unbeatable-tests.md"

spec:
  docs:
    - "README.md"
  dimensions:
    features:
$(echo -e "$FEATURES_YAML")
  blocked: []

verification:
  oracle:
    type: "deterministic"
    full_command: "$TEST_CMD"
    quick_command: "$QUICK_TEST_CMD"
    smoke_command: "$SMOKE_CMD"
    lint_command: "$LINT_CMD"
  preflight_env_vars: []
  stop_conditions:
    pass_rate_floor: 0.95
    max_consecutive_failures: 3
    test_count_decline_iters: 3
  skip_policy:
    ideate_fail: "continue"
    execute_fail: "continue"
    regress_fail: "pause"
  merge_gates:
    - "ci_pass"

ticketing:
  provider: "$TICKET_PROVIDER"
  github:
    labels:
      bug: "bug"
      feature: "enhancement"
      improvement: "improvement"
      exploration: "exploration"
    state_labels:
      todo: "kitchenloop:todo"
      in_progress: "kitchenloop:in-progress"
      in_review: "kitchenloop:in-review"
      done: "kitchenloop:done"

quality:
  bar_file: ".kitchenloop/quality-bar.md"

pr_manager:
  author_allowlist: []
  review_bot: "coderabbitai"
  require_ci: true
  skip_after_failures: 1

reviewers:
  codex:
    enabled: true
    timeout: 30
  gemini:
    enabled: false
    timeout: 60

runtime:
  timeouts:
    ideate: 2700
    triage: 1200
    execute: 3600
    polish: 5400
    regress: 9000
    backlog: 900
  backlog_interval: 3
  review_interval: 3
  polish_max_prs: 2
  drain_threshold: 10
  drain_exit_threshold: 5

# ─── UI Tests ────────────────────────────────────────────────────
# Uncomment and configure to enable --mode ui (browser-driven loop).
# Requires: app running locally + agent-browser installed (npm install -g agent-browser).
# ui_tests:
#   base_url: http://localhost:3000
#   screenshot_dir: .kitchenloop/ui-test-screenshots
#   screenshot_retention: 5
#   flows:
#     - id: example-flow
#       entry: /
#       goal: Describe what a user should accomplish
#       checkpoints:
#         - page renders without errors
#         - primary action works
#         - result visible to user

modes:
  default:
    ideate_prompt: "prompts/ideate.md"
  backtest:
    ideate_prompt: "prompts/ideate-backtest.md"
    description: "Exercise your testing pipeline"
  exploration:
    ideate_prompt: "prompts/ideate-exploration.md"
    description: "Explore coverage gaps"
  ui:
    ideate_prompt: "prompts/ideate-ui.md"
    description: "UI-driven loop: one browser flow per iteration, finds bugs early"
YAML_EOF

echo "  Created: kitchenloop.yaml"

# ─── Copy scripts ───────────────────────────────────────────────────────
echo "Copying scripts..."

mkdir -p "$REPO_ROOT/scripts/kitchenloop/prompts"
mkdir -p "$REPO_ROOT/scripts/kitchenloop/lib"
mkdir -p "$REPO_ROOT/scripts/pr-manager/prompts"

# Copy lib
for f in config.sh paths.sh tickets.sh; do
  cp "$KL_HOME/lib/$f" "$REPO_ROOT/scripts/kitchenloop/lib/$f"
done

# Copy orchestrator
cp "$KL_HOME/scripts/kitchenloop/kitchenloop.sh" "$REPO_ROOT/scripts/kitchenloop/kitchenloop.sh"
cp "$KL_HOME/scripts/kitchenloop/refresh-mcp-oauth.sh" "$REPO_ROOT/scripts/kitchenloop/refresh-mcp-oauth.sh"

# Copy prompts
for f in "$KL_HOME"/scripts/kitchenloop/prompts/*.md; do
  cp "$f" "$REPO_ROOT/scripts/kitchenloop/prompts/$(basename "$f")"
done

# Copy PR manager
cp "$KL_HOME/scripts/pr-manager/pr-manager.sh" "$REPO_ROOT/scripts/pr-manager/pr-manager.sh"
for f in "$KL_HOME"/scripts/pr-manager/prompts/*.md; do
  cp "$f" "$REPO_ROOT/scripts/pr-manager/prompts/$(basename "$f")"
done

# Copy Discussion Manager orchestrator
mkdir -p "$REPO_ROOT/scripts/ai-discussion"
# Source location: docs/internal/ in dev repo, scripts/ai-discussion/ in public repo
local _discuss_src="$KL_HOME/docs/internal/ai-discussion"
if [ ! -f "$_discuss_src/discuss.py" ]; then
  _discuss_src="$KL_HOME/scripts/ai-discussion"
fi
if [ -f "$_discuss_src/discuss.py" ]; then
  cp "$_discuss_src/discuss.py" "$REPO_ROOT/scripts/ai-discussion/discuss.py"
  cp "$_discuss_src/prep-codebase-context.sh" "$REPO_ROOT/scripts/ai-discussion/prep-codebase-context.sh"
else
  echo "  WARNING: discuss.py not found, skipping Discussion Manager copy"
fi

# Make scripts executable
chmod +x "$REPO_ROOT/scripts/kitchenloop/kitchenloop.sh"
chmod +x "$REPO_ROOT/scripts/kitchenloop/refresh-mcp-oauth.sh"
chmod +x "$REPO_ROOT/scripts/pr-manager/pr-manager.sh"
chmod +x "$REPO_ROOT/scripts/ai-discussion/discuss.py"
chmod +x "$REPO_ROOT/scripts/ai-discussion/prep-codebase-context.sh"

echo "  Scripts copied to scripts/kitchenloop/, scripts/pr-manager/, and scripts/ai-discussion/"

# ─── Copy skills ────────────────────────────────────────────────────────
echo "Copying skills..."

mkdir -p "$REPO_ROOT/.claude/skills"
for skill_dir in "$KL_HOME"/skills/*/; do
  skill_name=$(basename "$skill_dir")
  mkdir -p "$REPO_ROOT/.claude/skills/$skill_name"
  cp "$skill_dir"SKILL.md "$REPO_ROOT/.claude/skills/$skill_name/SKILL.md"
done

# Copy skills from .claude/skills/ (Discussion Manager, UAT gate support)
for skill_dir in "$KL_HOME"/.claude/skills/*/; do
  if [ -d "$skill_dir" ]; then
    skill_name=$(basename "$skill_dir")
    mkdir -p "$REPO_ROOT/.claude/skills/$skill_name"
    for f in "$skill_dir"*.md; do
      [ -f "$f" ] && cp "$f" "$REPO_ROOT/.claude/skills/$skill_name/$(basename "$f")"
    done
  fi
done

# Copy agent definitions
if [ -d "$KL_HOME/.claude/agents" ]; then
  mkdir -p "$REPO_ROOT/.claude/agents"
  for f in "$KL_HOME"/.claude/agents/*.md; do
    [ -f "$f" ] && cp "$f" "$REPO_ROOT/.claude/agents/$(basename "$f")"
  done
  echo "  Agent definitions copied to .claude/agents/"
fi

echo "  Skills copied to .claude/skills/"

# ─── Create artifact directories and initial files ───────────────────────
echo "Creating artifact directories..."

mkdir -p "$REPO_ROOT/docs/internal/reports"
mkdir -p "$REPO_ROOT/memory"
mkdir -p "$REPO_ROOT/.kitchenloop/logs"
mkdir -p "$REPO_ROOT/.kitchenloop/uat-cards"
mkdir -p "$REPO_ROOT/.kitchenloop/uat-runs"
mkdir -p "$REPO_ROOT/scenarios/incubating"

# Copy templates with variable substitution
substitute_vars() {
  local input="$1"
  local output="$2"
  sed \
    -e "s|{{PROJECT_NAME}}|${PROJECT_NAME}|g" \
    -e "s|{{PROJECT_DESC}}|${PROJECT_DESC}|g" \
    -e "s|{{PROJECT_LANG}}|${PROJECT_LANG}|g" \
    -e "s|{{BASE_BRANCH}}|${BASE_BRANCH}|g" \
    -e "s|{{TEST_COMMAND}}|${TEST_CMD}|g" \
    -e "s|{{QUICK_TEST_COMMAND}}|${QUICK_TEST_CMD}|g" \
    -e "s|{{LINT_COMMAND}}|${LINT_CMD}|g" \
    -e "s|{{TICKET_PROVIDER}}|${TICKET_PROVIDER}|g" \
    "$input" > "$output"
}

# Only create if not already present
if [ ! -f "$REPO_ROOT/docs/internal/loop-state.md" ]; then
  substitute_vars "$KL_HOME/templates/loop-state.md" "$REPO_ROOT/docs/internal/loop-state.md"
  echo "  Created: docs/internal/loop-state.md"
fi

if [ ! -f "$REPO_ROOT/.kitchenloop/quality-bar.md" ]; then
  substitute_vars "$KL_HOME/templates/quality-bar.md" "$REPO_ROOT/.kitchenloop/quality-bar.md"
  echo "  Created: .kitchenloop/quality-bar.md"
fi

if [ ! -f "$REPO_ROOT/memory/codebase-patterns.md" ]; then
  substitute_vars "$KL_HOME/templates/codebase-patterns.md" "$REPO_ROOT/memory/codebase-patterns.md"
  echo "  Created: memory/codebase-patterns.md"
fi

# Generate project-specific unbeatable tests guide
echo "Generating unbeatable tests guide..."

# Determine L3/L4 descriptions based on interaction type
case "${INTERACTION_TYPE,,}" in
  ui|web|frontend)
    UNBEATABLE_DEF="For a web application, ground truth = a real browser can load pages, interact with UI elements, and see correct results. The server must start, routes must resolve, and rendering must produce the expected DOM."
    L3_DESC="Start the real application server, send HTTP requests to real routes, and verify responses contain expected data. This proves the server boots, routes resolve, middleware runs, and the database is reachable.\n\nExample: \`npm start && curl -sf http://localhost:3000/ && curl -sf http://localhost:3000/api/health | grep ok\`"
    L4_DESC="Browser automation against the real running app. A headless browser loads pages, clicks buttons, fills forms, and asserts on visible content. This proves the product works as a user would experience it.\n\nExample: \`npx playwright test tests/e2e/smoke.spec.ts\` exercising a core user journey."
    ;;
  api|backend|server)
    UNBEATABLE_DEF="For an API service, ground truth = real HTTP requests return correct responses with correct status codes, and side effects (database writes, queue messages) actually happen."
    L3_DESC="Start the real server, send real HTTP requests to each major endpoint, and verify response status codes, body content, and database state changes.\n\nExample: \`python -m pytest tests/integration/ --real-server\`"
    L4_DESC="Multi-step API workflows that chain requests: create a resource, query it, update it, verify the update persists. This proves the API works as a client would use it."
    ;;
  cli|command-line|terminal)
    UNBEATABLE_DEF="For a CLI tool, ground truth = running the actual binary with real input produces correct output and expected side effects (files created, exit codes, stdout content)."
    L3_DESC="Run the real CLI binary with representative inputs and verify stdout content, exit codes, and filesystem side effects.\n\nExample: \`my-cli process input.json --output /tmp/result && test -f /tmp/result/output.json && jq '.status' /tmp/result/output.json | grep -q ok\`"
    L4_DESC="End-to-end workflows that chain CLI commands as a real user would: init a project, add data, run processing, export results. Verify the full pipeline produces correct final state."
    ;;
  library|sdk|package)
    UNBEATABLE_DEF="For a library, ground truth = importing the package and calling its public API with real inputs produces correct outputs and handles edge cases without crashing."
    L3_DESC="Integration scripts that import the library and exercise the public API with real (not mocked) dependencies. Verify return values, side effects, and error handling.\n\nExample: \`python -c \"from mylib import Client; assert Client().health() == 'ok'\"\`"
    L4_DESC="Realistic usage scenarios that chain multiple API calls as a consumer would: initialize, configure, process data, read results. Verify the library works in a realistic integration context."
    ;;
  *)
    UNBEATABLE_DEF="Ground truth for this project = exercising the real system end-to-end and verifying that actual state changes match expectations. Not mocks, not stubs — real execution."
    L3_DESC="Start the real system, send real inputs, and verify real outputs. The specific approach depends on your project's interaction model.\n\n**You should customize this section** with concrete examples for your project."
    L4_DESC="Complete user journeys that exercise the full system as a real user would. Chain multiple operations and verify the final state matches expectations."
    ;;
esac

# Determine smoke command display
if [ -n "$SMOKE_CMD" ]; then
  SMOKE_DISPLAY="$SMOKE_CMD"
else
  SMOKE_DISPLAY="(not yet configured — bootstrap in first loop iteration)"
fi

# Generate the file from template
if [ -f "$KL_HOME/templates/unbeatable-tests.md" ]; then
  sed \
    -e "s|{{PROJECT_NAME}}|${PROJECT_NAME}|g" \
    -e "s|{{SMOKE_COMMAND}}|${SMOKE_DISPLAY}|g" \
    "$KL_HOME/templates/unbeatable-tests.md" \
    > "$REPO_ROOT/.kitchenloop/unbeatable-tests.md"

  # Replace multi-line blocks with perl (sed can't handle multi-line easily)
  perl -i -0pe "s|\\{\\{UNBEATABLE_DEFINITION\\}\\}|${UNBEATABLE_DEF}|g" "$REPO_ROOT/.kitchenloop/unbeatable-tests.md"
  perl -i -0pe "s|\\{\\{L3_DESCRIPTION\\}\\}|${L3_DESC}|g" "$REPO_ROOT/.kitchenloop/unbeatable-tests.md"
  perl -i -0pe "s|\\{\\{L4_DESCRIPTION\\}\\}|${L4_DESC}|g" "$REPO_ROOT/.kitchenloop/unbeatable-tests.md"

  # Test audit placeholder — will be filled by first loop iteration
  if [ -n "$SMOKE_CMD" ]; then
    TEST_AUDIT="- L1/L2 (unit/adapter): Covered by \`$TEST_CMD\`\n- L3 (integration): Covered by \`$SMOKE_CMD\`\n- L4 (E2E): Covered by UAT gate"
  else
    TEST_AUDIT="- L1/L2 (unit/adapter): Covered by \`$TEST_CMD\`\n- **L3 (integration): NOT YET CONFIGURED** — first loop iteration should bootstrap this\n- L4 (E2E): Covered by UAT gate (once L3 exists)"
  fi
  perl -i -0pe "s|\\{\\{TEST_AUDIT\\}\\}|${TEST_AUDIT}|g" "$REPO_ROOT/.kitchenloop/unbeatable-tests.md"

  echo "  Created: .kitchenloop/unbeatable-tests.md"

  if [ -z "$SMOKE_CMD" ]; then
    echo ""
    echo "  *** WARNING: No L3 smoke test configured. ***"
    echo "  The regression gate will only run L1/L2 tests."
    echo "  The loop will prioritize bootstrapping an L3 test in its first iteration."
    echo "  You can also add one manually and set verification.oracle.smoke_command in kitchenloop.yaml."
  fi
fi

# ─── Template substitution in all copied files ──────────────────────────
echo "Applying template substitution..."

# Derive repo owner/name from remote
REPO_OWNER_SLASH_NAME=""
if [ -n "$DEFAULT_REMOTE" ]; then
  REPO_OWNER_SLASH_NAME=$(echo "$DEFAULT_REMOTE" | sed -E 's|.*[:/]([^/]+/[^/]+?)(\.git)?$|\1|')
fi

# Process all .md and .sh files in scripts/ and .claude/skills/
find "$REPO_ROOT/scripts/kitchenloop" "$REPO_ROOT/scripts/pr-manager" "$REPO_ROOT/.claude/skills" \
  -type f \( -name "*.md" -o -name "*.sh" \) | while IFS= read -r f; do
  sed -i '' \
    -e "s|{{PROJECT_NAME}}|${PROJECT_NAME}|g" \
    -e "s|{{PROJECT_DESC}}|${PROJECT_DESC}|g" \
    -e "s|{{PROJECT_LANG}}|${PROJECT_LANG}|g" \
    -e "s|{{BASE_BRANCH}}|${BASE_BRANCH}|g" \
    -e "s|{{TEST_COMMAND}}|${TEST_CMD}|g" \
    -e "s|{{QUICK_TEST_COMMAND}}|${QUICK_TEST_CMD}|g" \
    -e "s|{{LINT_COMMAND}}|${LINT_CMD}|g" \
    -e "s|{{FULL_TEST_COMMAND}}|${TEST_CMD}|g" \
    -e "s|{{SMOKE_COMMAND}}|${SMOKE_CMD}|g" \
    -e "s|{{TICKET_PROVIDER}}|${TICKET_PROVIDER}|g" \
    -e "s|{{REPO_OWNER_SLASH_NAME}}|${REPO_OWNER_SLASH_NAME}|g" \
    "$f" 2>/dev/null || true
done

echo "  Template variables substituted."

# ─── Validate ───────────────────────────────────────────────────────────
echo ""
echo "Validating..."

# Check for remaining template variables
REMNANTS=$(grep -r '{{[A-Z_]*}}' \
  "$REPO_ROOT/scripts/kitchenloop" \
  "$REPO_ROOT/scripts/pr-manager" \
  "$REPO_ROOT/.claude/skills" \
  "$REPO_ROOT/docs/internal/loop-state.md" \
  "$REPO_ROOT/.kitchenloop/quality-bar.md" \
  2>/dev/null | grep -v 'BLOCKED_COMBOS' | grep -v 'CUSTOMIZE' | head -5 || true)

if [ -n "$REMNANTS" ]; then
  echo "  WARNING: Unsubstituted template variables found:"
  echo "$REMNANTS" | while IFS= read -r line; do echo "    $line"; done
  echo "  (These may be intentional placeholders for runtime substitution)"
else
  echo "  No unsubstituted template variables found."
fi

# Validate config is readable
if yq '.project.name' "$REPO_ROOT/kitchenloop.yaml" >/dev/null 2>&1; then
  echo "  kitchenloop.yaml is valid YAML."
else
  echo "  WARNING: kitchenloop.yaml has YAML parsing issues."
fi

# ─── Update .gitignore ──────────────────────────────────────────────────
echo ""
echo "Updating .gitignore..."

GITIGNORE_ENTRIES=(
  ".kitchenloop/logs/"
  ".kitchenloop/uat-runs/"
  ".claude/worktrees/"
  "scripts/ai-discussion/conversations/"
)

for entry in "${GITIGNORE_ENTRIES[@]}"; do
  if ! grep -qF "$entry" "$REPO_ROOT/.gitignore" 2>/dev/null; then
    echo "$entry" >> "$REPO_ROOT/.gitignore"
    echo "  Added to .gitignore: $entry"
  fi
done

# ─── Done ───────────────────────────────────────────────────────────────
echo ""
echo "==========================================================="
echo "  KitchenLoop initialized for: $PROJECT_NAME"
echo "==========================================================="
echo ""
echo "Next steps:"
echo ""
echo "  1. Review kitchenloop.yaml and customize spec.dimensions"
echo "  2. Review .claude/skills/ and add domain knowledge"
echo "  3. Run your first loop:"
echo ""
echo "     cd $REPO_ROOT"
echo "     ./scripts/kitchenloop/kitchenloop.sh 1"
echo ""
echo "  4. Monitor: tail -f .kitchenloop/logs/kitchenloop.log"
echo ""
echo "  For backtest mode:  ./scripts/kitchenloop/kitchenloop.sh 1 --mode backtest"
echo "  For exploration:    ./scripts/kitchenloop/kitchenloop.sh 1 --mode exploration"
echo ""
