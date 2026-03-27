#!/bin/bash
# test-ticket-lifecycle.sh — Integration tests for lib/tickets.sh (local provider)
#
# Exercises the full ticket lifecycle using the local/none provider:
#   create → list → transition → comment → recover_stale → count
#
# Runs in ~2 seconds, no GitHub API calls, no side effects (uses temp dirs).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ─── File-based counters (survive subshells) ──────────────────────────
TMPDIR_TEST=$(mktemp -d)
echo 0 > "$TMPDIR_TEST/pass"
echo 0 > "$TMPDIR_TEST/fail"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

pass() {
  local c; c=$(cat "$TMPDIR_TEST/pass")
  echo $((c + 1)) > "$TMPDIR_TEST/pass"
  echo "  ✓ $1"
}

fail() {
  local c; c=$(cat "$TMPDIR_TEST/fail")
  echo $((c + 1)) > "$TMPDIR_TEST/fail"
  echo "  ✗ $1"
}

# ─── Helper: run a test in an isolated subshell with fresh env ─────────
# Args: test_name test_body_function
# The function receives $TEST_PROJECT as a temp project dir with a config.
run_test() {
  local name="$1"
  shift
  local body="$*"

  local project_dir
  project_dir=$(mktemp -d)

  # Create a minimal kitchenloop.yaml with local ticketing provider
  cat > "$project_dir/kitchenloop.yaml" <<'YAML'
project:
  name: "test-project"
  language: "bash"
ticketing:
  provider: "local"
  github:
    labels:
      bug: "bug"
      feature: "enhancement"
    state_labels:
      todo: "kitchenloop:todo"
      in_progress: "kitchenloop:in-progress"
      in_review: "kitchenloop:in-review"
      done: "kitchenloop:done"
YAML

  # Run the test body in a subshell with clean state
  local output
  output=$(bash -c "
    set -uo pipefail
    export KITCHENLOOP_CONFIG='$project_dir/kitchenloop.yaml'
    export KITCHENLOOP_ROOT='$project_dir'

    # Unset guard variables so libraries load fresh
    unset _KITCHENLOOP_CONFIG_LOADED
    unset _KITCHENLOOP_TICKETS_LOADED

    source '$REPO_ROOT/lib/config.sh'
    config_load

    source '$REPO_ROOT/lib/tickets.sh'

    TEST_PROJECT='$project_dir'
    $body
  " 2>&1)
  local rc=$?

  if [ $rc -eq 0 ]; then
    pass "$name"
  else
    fail "$name: $output"
  fi

  rm -rf "$project_dir"
}

# ─── Helper: run a test that expects failure (non-zero exit) ──────────
run_test_expect_fail() {
  local name="$1"
  shift
  local body="$*"

  local project_dir
  project_dir=$(mktemp -d)

  cat > "$project_dir/kitchenloop.yaml" <<'YAML'
project:
  name: "test-project"
  language: "bash"
ticketing:
  provider: "local"
YAML

  local output
  output=$(bash -c "
    set -uo pipefail
    export KITCHENLOOP_CONFIG='$project_dir/kitchenloop.yaml'
    export KITCHENLOOP_ROOT='$project_dir'
    unset _KITCHENLOOP_CONFIG_LOADED
    unset _KITCHENLOOP_TICKETS_LOADED
    source '$REPO_ROOT/lib/config.sh'
    config_load
    source '$REPO_ROOT/lib/tickets.sh'
    TEST_PROJECT='$project_dir'
    $body
  " 2>&1)
  local rc=$?

  if [ $rc -ne 0 ]; then
    pass "$name (expected failure)"
  else
    fail "$name: expected non-zero exit but got 0. Output: $output"
  fi

  rm -rf "$project_dir"
}

echo "=== Ticket Adapter — Local Provider Integration Tests ==="

# ─── 1. Basic ticket creation ─────────────────────────────────────────
echo "--- Ticket creation"

run_test "create returns a non-empty ID" '
  id=$(ticket_create "Test bug" "Description" "bug" "high")
  [ -n "$id" ]
'

run_test "create writes to backlog.json" '
  ticket_create "Test ticket" "Body text" "feature" "medium" >/dev/null
  f="$TEST_PROJECT/.kitchenloop/backlog.json"
  [ -f "$f" ] && [ "$(jq length "$f")" -eq 1 ]
'

run_test "created ticket has correct title" '
  ticket_create "My Title" "Body" "bug" "low" >/dev/null
  f="$TEST_PROJECT/.kitchenloop/backlog.json"
  title=$(jq -r ".[0].title" "$f")
  [ "$title" = "My Title" ]
'

run_test "created ticket starts in backlog state" '
  ticket_create "State test" "" "feature" "medium" >/dev/null
  f="$TEST_PROJECT/.kitchenloop/backlog.json"
  state=$(jq -r ".[0].state" "$f")
  [ "$state" = "backlog" ]
'

run_test "created ticket stores type and priority" '
  ticket_create "Type test" "" "bug" "high" >/dev/null
  f="$TEST_PROJECT/.kitchenloop/backlog.json"
  type=$(jq -r ".[0].type" "$f")
  priority=$(jq -r ".[0].priority" "$f")
  [ "$type" = "bug" ] && [ "$priority" = "high" ]
'

run_test "created ticket has ISO timestamp" '
  ticket_create "Timestamp test" "" "feature" "medium" >/dev/null
  f="$TEST_PROJECT/.kitchenloop/backlog.json"
  created=$(jq -r ".[0].created" "$f")
  echo "$created" | grep -qE "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"
'

run_test "multiple creates produce unique IDs" '
  id1=$(ticket_create "First" "" "bug" "low")
  id2=$(ticket_create "Second" "" "bug" "low")
  [ "$id1" != "$id2" ]
'

run_test "create with empty body defaults gracefully" '
  id=$(ticket_create "No body" "" "feature" "medium")
  f="$TEST_PROJECT/.kitchenloop/backlog.json"
  body=$(jq -r ".[0].body" "$f")
  [ "$body" = "" ]
'

# ─── 2. Listing by state ──────────────────────────────────────────────
echo "--- List by state"

run_test "list_by_state returns empty array when no tickets" '
  result=$(ticket_list_by_state "todo")
  [ "$(echo "$result" | jq length)" -eq 0 ]
'

run_test "list_by_state returns tickets in correct state" '
  ticket_create "Backlog 1" "" "bug" "high" >/dev/null
  ticket_create "Backlog 2" "" "feature" "low" >/dev/null
  result=$(ticket_list_by_state "backlog")
  [ "$(echo "$result" | jq length)" -eq 2 ]
'

run_test "list_by_state filters correctly across states" '
  id1=$(ticket_create "Will transition" "" "bug" "high")
  ticket_create "Stays in backlog" "" "feature" "low" >/dev/null
  ticket_transition "$id1" "todo"
  backlog=$(ticket_list_by_state "backlog")
  todo=$(ticket_list_by_state "todo")
  [ "$(echo "$backlog" | jq length)" -eq 1 ] && [ "$(echo "$todo" | jq length)" -eq 1 ]
'

# ─── 3. State transitions ─────────────────────────────────────────────
echo "--- State transitions"

run_test "transition backlog → todo" '
  id=$(ticket_create "Trans test" "" "bug" "high")
  ticket_transition "$id" "todo"
  f="$TEST_PROJECT/.kitchenloop/backlog.json"
  state=$(jq -r ".[0].state" "$f")
  [ "$state" = "todo" ]
'

run_test "transition todo → in_progress → in_review → done" '
  id=$(ticket_create "Full lifecycle" "" "bug" "high")
  ticket_transition "$id" "todo"
  ticket_transition "$id" "in_progress"
  ticket_transition "$id" "in_review"
  ticket_transition "$id" "done"
  f="$TEST_PROJECT/.kitchenloop/backlog.json"
  state=$(jq -r ".[0].state" "$f")
  [ "$state" = "done" ]
'

run_test "transition rejects invalid state" '
  id=$(ticket_create "Invalid state" "" "bug" "high")
  ! ticket_transition "$id" "invalid_state" 2>/dev/null
'

run_test "transition only affects targeted ticket" '
  id1=$(ticket_create "Keep" "" "bug" "high")
  id2=$(ticket_create "Move" "" "feature" "low")
  ticket_transition "$id2" "todo"
  f="$TEST_PROJECT/.kitchenloop/backlog.json"
  s1=$(jq -r --arg i "$id1" ".[] | select(.id == \$i) | .state" "$f")
  s2=$(jq -r --arg i "$id2" ".[] | select(.id == \$i) | .state" "$f")
  [ "$s1" = "backlog" ] && [ "$s2" = "todo" ]
'

# ─── 4. Comments ──────────────────────────────────────────────────────
echo "--- Comments"

run_test "add_comment appends to notes field" '
  id=$(ticket_create "Comment test" "" "bug" "high")
  ticket_add_comment "$id" "First comment"
  f="$TEST_PROJECT/.kitchenloop/backlog.json"
  notes=$(jq -r ".[0].notes" "$f")
  echo "$notes" | grep -q "First comment"
'

run_test "multiple comments accumulate" '
  id=$(ticket_create "Multi comment" "" "bug" "high")
  ticket_add_comment "$id" "Comment A"
  ticket_add_comment "$id" "Comment B"
  f="$TEST_PROJECT/.kitchenloop/backlog.json"
  notes=$(jq -r ".[0].notes" "$f")
  echo "$notes" | grep -q "Comment A" && echo "$notes" | grep -q "Comment B"
'

# ─── 5. Count by state ────────────────────────────────────────────────
echo "--- Count by state"

run_test "count_by_state returns 0 for empty backlog" '
  count=$(ticket_count_by_state "backlog")
  [ "$count" -eq 0 ]
'

run_test "count_by_state returns correct count" '
  ticket_create "A" "" "bug" "high" >/dev/null
  ticket_create "B" "" "bug" "low" >/dev/null
  ticket_create "C" "" "feature" "medium" >/dev/null
  count=$(ticket_count_by_state "backlog")
  [ "$count" -eq 3 ]
'

run_test "count_by_state reflects transitions" '
  id=$(ticket_create "Count trans" "" "bug" "high")
  ticket_create "Stay" "" "feature" "low" >/dev/null
  ticket_transition "$id" "todo"
  backlog_count=$(ticket_count_by_state "backlog")
  todo_count=$(ticket_count_by_state "todo")
  [ "$backlog_count" -eq 1 ] && [ "$todo_count" -eq 1 ]
'

# ─── 6. Recover stale ─────────────────────────────────────────────────
echo "--- Recover stale"

run_test "recover_stale moves in_progress tickets with no PR back to todo" '
  id=$(ticket_create "Stale ticket" "" "bug" "high")
  ticket_transition "$id" "todo"
  ticket_transition "$id" "in_progress"
  ticket_recover_stale >/dev/null
  f="$TEST_PROJECT/.kitchenloop/backlog.json"
  state=$(jq -r ".[0].state" "$f")
  [ "$state" = "todo" ]
'

run_test "recover_stale preserves in_progress tickets with PR URL" '
  id=$(ticket_create "Has PR" "" "bug" "high")
  ticket_transition "$id" "in_progress"
  f="$TEST_PROJECT/.kitchenloop/backlog.json"
  # Manually set pr_url to simulate a ticket with an associated PR
  updated=$(jq --arg i "$id" "map(if .id == \$i then .pr_url = \"https://github.com/test/1\" else . end)" "$f")
  echo "$updated" > "$f"
  ticket_recover_stale >/dev/null
  state=$(jq -r ".[0].state" "$f")
  [ "$state" = "in_progress" ]
'

run_test "recover_stale does not touch other states" '
  id1=$(ticket_create "Backlog ticket" "" "bug" "high")
  id2=$(ticket_create "Done ticket" "" "feature" "low")
  ticket_transition "$id2" "done"
  ticket_recover_stale >/dev/null
  f="$TEST_PROJECT/.kitchenloop/backlog.json"
  s1=$(jq -r --arg i "$id1" ".[] | select(.id == \$i) | .state" "$f")
  s2=$(jq -r --arg i "$id2" ".[] | select(.id == \$i) | .state" "$f")
  [ "$s1" = "backlog" ] && [ "$s2" = "done" ]
'

# ─── 7. ticket_get ───────────────────────────────────────────────────
echo "--- ticket_get"

run_test "ticket_get returns ticket JSON" '
  id=$(ticket_create "Get test" "Body" "bug" "high")
  result=$(ticket_get "$id")
  title=$(echo "$result" | jq -r ".title")
  [ "$title" = "Get test" ]
'

run_test_expect_fail "ticket_get fails for nonexistent ID" '
  ticket_get "nonexistent_id_12345"
'

# ─── 8. ticket_set_pr_url ────────────────────────────────────────────
echo "--- ticket_set_pr_url"

run_test "ticket_set_pr_url updates pr_url field" '
  id=$(ticket_create "PR URL test" "" "bug" "high")
  ticket_set_pr_url "$id" "https://github.com/test/pulls/1"
  f="$TEST_PROJECT/.kitchenloop/backlog.json"
  url=$(jq -r ".[0].pr_url" "$f")
  [ "$url" = "https://github.com/test/pulls/1" ]
'

run_test_expect_fail "ticket_set_pr_url fails for nonexistent ID" '
  ticket_set_pr_url "nonexistent_id_12345" "https://example.com"
'

# ─── 9. ID validation ───────────────────────────────────────────────
echo "--- ID validation"

run_test_expect_fail "ticket_transition fails for nonexistent ID" '
  ticket_transition "nonexistent_id_12345" "todo"
'

run_test_expect_fail "ticket_add_comment fails for nonexistent ID" '
  ticket_add_comment "nonexistent_id_12345" "Should fail"
'

# ─── 10. First comment has no leading newline ─────────────────────────
echo "--- Comment formatting"

run_test "first comment has no leading newline" '
  id=$(ticket_create "Newline test" "" "bug" "high")
  ticket_add_comment "$id" "First comment"
  f="$TEST_PROJECT/.kitchenloop/backlog.json"
  notes=$(jq -r ".[0].notes" "$f")
  [ "$notes" = "First comment" ]
'

# ─── 11. Provider detection ───────────────────────────────────────────
echo "--- Provider edge cases"

run_test "unknown provider returns error on create" '
  # Override the provider in the config
  f="$TEST_PROJECT/kitchenloop.yaml"
  echo "project:
  name: test
ticketing:
  provider: unsupported_provider" > "$f"
  unset _KITCHENLOOP_CONFIG_LOADED
  source "'$REPO_ROOT'/lib/config.sh"
  config_load
  ! ticket_create "Should fail" "" "bug" "high" 2>/dev/null
'

# ─── 12. Guard variables ─────────────────────────────────────────────
echo "--- Guard & dependency checks"

run_test "tickets.sh requires config.sh loaded first" '
  output=$(bash -c "
    unset _KITCHENLOOP_CONFIG_LOADED
    unset _KITCHENLOOP_TICKETS_LOADED
    source \"'$REPO_ROOT'/lib/tickets.sh\"
  " 2>&1) || true
  echo "$output" | grep -q "requires config.sh"
'

# ─── Summary ──────────────────────────────────────────────────────────
echo ""
PASS_COUNT=$(cat "$TMPDIR_TEST/pass")
FAIL_COUNT=$(cat "$TMPDIR_TEST/fail")
echo "--- Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
