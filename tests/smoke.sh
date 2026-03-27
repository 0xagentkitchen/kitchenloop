#!/bin/bash
# smoke.sh — Quick sanity checks for KitchenLoop
#
# Validates bash syntax, source-ability of libraries, file structure,
# and config parsing. Runs in ~2 seconds with no side effects.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; }

# ─── 1. Bash syntax check on all scripts ────────────────────────
echo "--- Syntax check"
while IFS= read -r script; do
  if bash -n "$script" 2>/dev/null; then
    pass "syntax: ${script#$REPO_ROOT/}"
  else
    fail "syntax: ${script#$REPO_ROOT/}"
  fi
done < <(find "$REPO_ROOT/scripts" "$REPO_ROOT/lib" -name '*.sh' -type f 2>/dev/null)

# ─── 2. Required files exist ────────────────────────────────────
echo "--- Required files"
for f in \
  kitchenloop.yaml \
  kitchenloop.example.yaml \
  CLAUDE.md \
  README.md \
  docs/howto.md \
  lib/config.sh \
  lib/paths.sh \
  lib/tickets.sh \
  scripts/kitchenloop/kitchenloop.sh \
  scripts/pr-manager/pr-manager.sh \
  scripts/ai-discussion/discuss.py; do
  if [ -f "$REPO_ROOT/$f" ]; then
    pass "exists: $f"
  else
    fail "missing: $f"
  fi
done

# ─── 3. Phase prompts exist ─────────────────────────────────────
echo "--- Phase prompts"
for phase in ideate ideate-backtest ideate-exploration triage execute polish regress backlog; do
  f="scripts/kitchenloop/prompts/${phase}.md"
  if [ -f "$REPO_ROOT/$f" ]; then
    pass "prompt: $phase"
  else
    fail "prompt missing: $phase"
  fi
done

# ─── 4. Scripts are executable ──────────────────────────────────
echo "--- Executable bits"
for f in \
  scripts/kitchenloop/kitchenloop.sh \
  scripts/pr-manager/pr-manager.sh \
  scripts/ai-discussion/discuss.py; do
  if [ -x "$REPO_ROOT/$f" ]; then
    pass "executable: $f"
  else
    fail "not executable: $f"
  fi
done

# ─── 5. Config loader sources without error ─────────────────────
echo "--- Library sourcing"
(
  # Subshell so we don't pollute the test environment
  cd "$REPO_ROOT"
  export KITCHENLOOP_CONFIG="$REPO_ROOT/kitchenloop.yaml"

  # config.sh needs yq — skip if not installed
  if ! command -v yq &>/dev/null; then
    echo "  ~ skipped: config.sh (yq not installed)"
  else
    # Source config and validate basic reads
    source "$REPO_ROOT/lib/config.sh"
    config_load

    name=$(config_get "project.name")
    if [ "$name" = "kitchenloop" ]; then
      pass "config_get project.name = kitchenloop"
    else
      fail "config_get project.name = '$name' (expected 'kitchenloop')"
    fi

    lang=$(config_get "project.language")
    if [ "$lang" = "bash" ]; then
      pass "config_get project.language = bash"
    else
      fail "config_get project.language = '$lang' (expected 'bash')"
    fi

    features=$(config_get_list "spec.dimensions.features" | wc -l | tr -d ' ')
    if [ "$features" -ge 5 ]; then
      pass "spec.dimensions.features has $features entries"
    else
      fail "spec.dimensions.features has only $features entries (expected ≥5)"
    fi
  fi
)

# ─── 6. YAML validity ───────────────────────────────────────────
echo "--- YAML validity"
if command -v yq &>/dev/null; then
  for f in kitchenloop.yaml kitchenloop.example.yaml; do
    if yq '.' "$REPO_ROOT/$f" >/dev/null 2>&1; then
      pass "valid YAML: $f"
    else
      fail "invalid YAML: $f"
    fi
  done
else
  echo "  ~ skipped: YAML validation (yq not installed)"
fi

# ─── Summary ────────────────────────────────────────────────────
echo ""
echo "--- Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
