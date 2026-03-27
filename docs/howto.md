# How-To Guide

Operator manual for running, monitoring, and troubleshooting KitchenLoop.

---

## Starting Your First Loop

### Prerequisites Check

```bash
# Verify all tools are installed
claude --version        # Claude Code CLI
git --version           # Git
gh --version            # GitHub CLI
jq --version            # JSON processor
yq --version            # YAML processor
```

### Initialize

From your project root:

```bash
# Generate kitchenloop.yaml with sensible defaults
/path/to/kitchenloop/scripts/kitchenloop-init.sh

# Review and edit the config
$EDITOR kitchenloop.yaml
```

The init script auto-detects your language, test command, and project structure.
Review the generated config before running.

### Run a Single Iteration

```bash
# One iteration, then stop
./scripts/kitchenloop/kitchenloop.sh 1

# One iteration in backtest mode
./scripts/kitchenloop/kitchenloop.sh 1 --mode backtest
```

### Run Multiple Iterations

```bash
# Run 10 iterations
./scripts/kitchenloop/kitchenloop.sh 10

# Run 5 iterations in exploration mode
./scripts/kitchenloop/kitchenloop.sh 5 --mode exploration

# Run until a stop condition is hit (no loop count)
./scripts/kitchenloop/kitchenloop.sh
```

### Available Modes

| Mode | Flag | Description |
|------|------|-------------|
| strategy | `--mode strategy` | Default. Full loop: ideate → triage → execute → polish → regress |
| backtest | `--mode backtest` | Exercises your testing pipeline with synthetic scenarios |
| exploration | `--mode exploration` | Focuses on coverage gaps in the spec surface |
| user-only | `--mode user-only` | Rapid ideation + triage only (fills the backlog fast) |
| dev-only | `--mode dev-only` | Implementation only, works off existing backlog |
| ui | `--mode ui` | UI-driven loop: one browser flow per iteration |

### UI Mode

UI mode runs one browser flow per iteration instead of the standard synthetic user scenario. It requires:
- The app to be running locally (`make dev` or equivalent)
- `agent-browser` installed (`npm install -g agent-browser`)
- `ui_tests.flows` configured in `kitchenloop.yaml`

```bash
# Start your app first
make dev &

# Then run UI-driven iterations
./scripts/kitchenloop/kitchenloop.sh 10 --mode ui
```

Each iteration: picks the next pending flow → runs it in the browser → writes an evidence report → triage creates tickets → bug reproducer hook validates bugs → execute fixes them.

The state file at `.kitchenloop/ui-test-state.json` tracks which flows have been tested. When all flows are tested, it wraps around and starts again.

---

## Monitoring a Running Loop

### Tail the Log

```bash
tail -f .kitchenloop/loop.log
```

The log shows phase transitions, decisions, test results, and merge outcomes in
real time.

### Check Loop State

```bash
cat .kitchenloop/loop-state.md
```

This human-readable file is updated after every phase. It shows:
- Current iteration and phase
- Pass rate and test count
- Consecutive failures
- Spec surface coverage percentage
- Last merged PR

### Check Coverage

```bash
# Summary
jq '{total: .total_combinations, covered: .covered_combinations, pct: .coverage_pct}' \
  .kitchenloop/coverage-map.json

# Uncovered coordinates
jq '[.dimensions as $dims |
  .entries | map(.coordinates) |
  . as $covered |
  "See full coverage map for gaps"]' \
  .kitchenloop/coverage-map.json
```

### Watch PRs

```bash
# List KitchenLoop PRs
gh pr list --label kitchenloop

# Check latest PR status
gh pr view $(gh pr list --label kitchenloop --limit 1 --json number -q '.[0].number')
```

---

## Interpreting loop-state.md

```markdown
# Loop State

- **Iteration**: 42
- **Mode**: strategy
- **Status**: running (phase: REGRESS)
- **Pass rate**: 97.3% (floor: 95%)
- **Test count**: 312 (baseline: 289)
- **Consecutive failures**: 0
- **Coverage**: 30.3% (23/76)
- **Last merge**: iter-41, PR #87
- **Backlog**: 11 open, 3 blocked
```

Key indicators:

| Field | Healthy | Warning | Action |
|-------|---------|---------|--------|
| Pass rate | Above floor + 2% | Within 1% of floor | Review recent merges, consider pausing |
| Consecutive failures | 0 | 2+ | Check iteration reports for pattern |
| Coverage | Increasing | Flat for 5+ iterations | Review spec surface definition |
| Backlog (blocked) | 0-2 | 5+ | Manually unblock or remove stale tickets |

---

## Handling Stuck PRs

A PR can get stuck if:
- CI is slow or failing for external reasons
- A reviewer is unresponsive (human review mode)
- GitHub API rate limits are hit

### Diagnose

```bash
# Check open KitchenLoop PRs
gh pr list --label kitchenloop --state open

# Check a specific PR's status
gh pr checks <PR_NUMBER>
```

### Resolve

```bash
# Close a stuck PR and return its ticket to backlog
gh pr close <PR_NUMBER>
# The next iteration will pick up the ticket

# Or merge manually if tests pass
gh pr merge <PR_NUMBER> --squash
```

---

## Handling Failed Iterations

### Check the Iteration Report

```bash
cat .kitchenloop/artifacts/iter-{N}-report.md
```

The report includes:
- Which phase failed
- Error output
- Files that were modified
- Test results (if the iteration reached Regress)

### Common Failure Patterns

**Triage rejected (repeatedly):**
The ideation is producing proposals that the reviewer rejects. Check:
- Is the spec surface too broad? Narrow the dimensions.
- Is the reviewer too conservative? Increase `max_rejections` or switch provider.

**Execute failed (lint/smoke):**
The generated code has quality issues. Check:
- Is the lint command correct? Run it manually.
- Are there project-specific conventions not captured in `CLAUDE.md`?

**Regress failed:**
The change broke existing tests. This is normal and expected. The loop will:
1. Close the PR
2. Return the ticket to backlog
3. Try a different approach next time

If the same ticket fails 3 times (configurable via `max_attempts` in the ticket
schema), it moves to `blocked` state.

**Regress failed (pass rate below floor):**
A merge made the test suite worse. This should be rare (the loop checks before
merging) but can happen with flaky tests. Review the merge and consider:
- Reverting the PR
- Adjusting `min_pass_rate` if the floor is too tight

---

## Running Specific Phases

### Skip Phases

```bash
# Skip ideation (only work on existing backlog)
./scripts/kitchenloop/kitchenloop.sh 5 --skip ideate

# Skip triage (no external review)
./scripts/kitchenloop/kitchenloop.sh 5 --skip triage
```

### Run Only Specific Phases

```bash
# Only run ideation each loop
./scripts/kitchenloop/kitchenloop.sh 5 --only ideate

# Only run regression
./scripts/kitchenloop/kitchenloop.sh 1 --only regress
```

Phase names: `backlog`, `ideate`, `triage`, `execute`, `polish`, `regress`

---

## Drain Mode

When the backlog grows too large (exceeds `runtime.drain_threshold` in kitchenloop.yaml), the loop automatically enters drain mode: it skips ideation and only works through existing tickets.

### Force Dev-Only Mode (Manual Drain)

```bash
# Skip ideation, only work on existing backlog
./scripts/kitchenloop/kitchenloop.sh 10 --mode dev-only
```

### Backlog Management

```bash
# View backlog
jq '.[] | {id, title, state, attempts}' .kitchenloop/backlog.json

# Remove a stale ticket
jq 'map(select(.id != "kl-17"))' .kitchenloop/backlog.json > tmp && mv tmp .kitchenloop/backlog.json

# Reset a blocked ticket to backlog
jq 'map(if .id == "kl-23" then .state = "backlog" | .attempts = 0 else . end)' \
  .kitchenloop/backlog.json > tmp && mv tmp .kitchenloop/backlog.json
```

---

## Emergency Stop

### Ctrl+C Behavior

Pressing Ctrl+C triggers graceful shutdown:

1. **During Backlog/Ideate/Triage**: Stop immediately, write loop state, exit.
2. **During Execute**: Discard worktree, write loop state, exit.
3. **During Polish**: If PR is already open, leave it open for manual review.
   Write loop state, exit.
4. **During Regress**: Wait for the current test run to finish (up to 60s
   timeout), evaluate results, then exit. If timeout is exceeded, discard.

A second Ctrl+C forces immediate exit. The worktree may be left behind and will
be cleaned up on the next run.

### Post-Emergency Cleanup

After an emergency stop:

```bash
# Check for stale worktrees
git worktree list

# Remove stale worktrees
git worktree remove .kitchenloop/worktrees/iter-{N} --force

# Check for orphaned branches
git branch | grep kitchenloop/

# Check for orphaned PRs
gh pr list --label kitchenloop --state open
```

---

## Tips for Long-Running Loops

- **Start small**: Run 5-10 iterations before going continuous
- **Review early PRs**: Check the first few merged PRs manually to calibrate
- **Tune the spec surface**: If iterations are too broad, narrow dimensions
- **Watch the pass rate**: A declining pass rate means the loop is introducing
  instability. Pause and review recent merges.
- **Rotate modes**: Run `strategy` mode for 20 iterations, then `dev_only` for
  10 to harden tests, then back to `strategy`
- **Check blocked tickets weekly**: Manually unblock or remove tickets that the
  loop cannot handle

## Overnight / Unattended Runs

### System Preparation

Before running the loop unattended (e.g., overnight), prepare the environment:

```bash
# Raise file descriptor limit (prevents EMFILE on macOS)
ulimit -n 10240

# Kill any leftover dev servers to free ports
lsof -ti :3000 | xargs kill -9 2>/dev/null || true
sleep 5  # Wait for port release

# For web apps: start your dev server in the background
npm run dev &
DEV_PID=$!
sleep 10  # Wait for server to be fully ready

# Run the loop
./scripts/kitchenloop/kitchenloop.sh 10 --mode ui

# Cleanup
kill $DEV_PID 2>/dev/null
```

### Common Overnight Issues

| Issue | Symptom | Fix |
|-------|---------|-----|
| EMFILE | `too many open files` | `ulimit -n 10240` before starting |
| Port conflict | Server fails to start | `lsof -ti :PORT \| xargs kill -9` |
| Stale server | 404 on all routes | Kill and restart dev server |
| `claude --print` empty | All phases produce 0 bytes | The orchestrator auto-detects this and falls back to stream-json extraction |
