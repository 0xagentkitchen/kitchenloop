# Kitchen Loop - Phase 1: Ideate (UI Mode)

You are running **autonomously** as part of the Kitchen Loop. There is no human operator to interact with. You must make all decisions yourself and proceed without asking questions.

## Autonomous Mode Rules

1. **Do NOT use `EnterPlanMode` or `ExitPlanMode`**. Plan your approach internally, then proceed directly to implementation.
2. **Do NOT use `AskUserQuestion`**. Make reasonable decisions and document them in the experience report.
3. **Do NOT use the Write tool to output status messages.** Only use Write/Edit for actual code and documentation files.

## Loop Context
- **Repo root**: {{REPO_ROOT}}
- **Iteration worktree**: {{ITER_WORKTREE}}
- **Iteration number**: {{ITERATION_NUM}}
- **Mode**: ui
- **Base branch**: {{BASE_BRANCH}}
- **Important**: You are running inside a git worktree, NOT the main repo directory. All file writes go to this worktree.

## The Project You Are Testing

**{{PROJECT_NAME}}**: {{PROJECT_DESC}}

{{PROJECT_ROOT_DIRECTIVE}}

### How Users Interact With This Project
{{PROJECT_CONTEXT}}

### Spec Surface (features × scenarios)
{{SPEC_SURFACE}}

## UI Test Configuration

Read `ui_tests` from `kitchenloop.yaml` in the project root. This section contains:
- `base_url` — where the app runs
- `screenshot_dir` — where to save screenshots
- `screenshot_retention` — how many iterations of screenshots to keep
- `flows` — list of test flows, each with `id`, `entry`, `goal`, `checkpoints`

## State File

The UI test state lives at `.kitchenloop/ui-test-state.json`. Example:
```json
{
  "flows_pending": ["shopping-list", "add-edit-delete-meal", "empty-states"],
  "flows_tested": ["plan-week"],
  "last_flow": "plan-week",
  "last_iteration": 2
}
```

When `flows_pending` is empty, reset: move all flows back to `flows_pending` (wrap-around).

## Your Task

**CRITICAL -- Output a sentinel line as your absolute first action** (before reading files or running any commands):

```
[ideate-ui] STARTED -- iteration {{ITERATION_NUM}}, mode={{MODE}}
```

### Step 1: Check Preconditions

Read config values:
```bash
BASE_URL="$(yq '.ui_tests.base_url' kitchenloop.yaml)"
SCREENSHOT_DIR="$(yq '.ui_tests.screenshot_dir' kitchenloop.yaml)"
SCREENSHOT_RETENTION="$(yq '.ui_tests.screenshot_retention // 5' kitchenloop.yaml)"
```

1. **App reachable?**
   ```bash
   curl -s -o /dev/null -w "%{http_code}" "$BASE_URL"
   ```
   - If not 200: write evidence.md with `SKIP: app not running at $BASE_URL`, exit with non-zero status.
   - This forces the operator to start the app before running UI mode.

2. **agent-browser available?** Resolve the command to use for all subsequent browser steps:
   ```bash
   if command -v agent-browser 2>/dev/null; then
     AGENT_BROWSER="agent-browser"
   elif npx --yes agent-browser --version 2>/dev/null; then
     AGENT_BROWSER="npx agent-browser"
   else
     AGENT_BROWSER=""
   fi
   ```
   - If `AGENT_BROWSER` is empty: write evidence.md with `SKIP: agent-browser not available`, set overall result to SKIP, continue to Step 5 (write experience report noting the skip).

3. **State file exists?** If `.kitchenloop/ui-test-state.json` does not exist, initialize it:
   ```json
   {
     "flows_pending": ["<all flow ids from kitchenloop.yaml>"],
     "flows_tested": [],
     "last_flow": null,
     "last_iteration": 0
   }
   ```

### Step 2: Pick Next Flow

Load `.kitchenloop/ui-test-state.json`. Take the first item from `flows_pending`. Look up its `entry`, `goal`, and `checkpoints` from `kitchenloop.yaml`.

If `flows_pending` is empty, reset first: set `flows_pending` to all flow IDs and `flows_tested` to `[]`.

### Step 3: Run the Flow

Create output directory: `.kitchenloop/ui-test-runs/{{FLOW_ID}}-{{ITERATION_NUM}}/`

Run the flow using `$AGENT_BROWSER` (resolved in Step 1):

```bash
# Open and wait for load
$AGENT_BROWSER open "${BASE_URL}${FLOW_ENTRY}"
$AGENT_BROWSER wait --load networkidle

# Screenshot: entry state (filename includes flow id AND iteration number)
$AGENT_BROWSER screenshot "${SCREENSHOT_DIR}/{{FLOW_ID}}-{{ITERATION_NUM}}-01-entry.png"

# Get element references
$AGENT_BROWSER snapshot -i

# Interact per flow goal (adapt based on what snapshot shows)
# After each significant action, capture state:
$AGENT_BROWSER screenshot "${SCREENSHOT_DIR}/{{FLOW_ID}}-{{ITERATION_NUM}}-02-action.png"
# Continue incrementing the counter for each screenshot: -03-, -04-, etc.
```

For each checkpoint in the flow:
- Attempt to verify it via snapshot or DOM inspection
- Record verdict: PASS / FAIL / PARTIAL / SKIP

### Step 4: Write Evidence Report

Write to `.kitchenloop/ui-test-runs/{{FLOW_ID}}-{{ITERATION_NUM}}/evidence.md`:

```markdown
# UI Test Evidence — {{FLOW_ID}} — Iteration {{ITERATION_NUM}}

**Flow**: {{FLOW_ID}}
**Entry**: {{FLOW_ENTRY}}
**Goal**: {{FLOW_GOAL}}
**Date**: [date]
**Overall**: PASS | FAIL | PARTIAL | SKIP

## Checkpoint Results

| Checkpoint | Result | Notes |
|-----------|--------|-------|
| [checkpoint 1] | PASS/FAIL | [observation] |
| [checkpoint 2] | PASS/FAIL | [observation] |

## Friction Points

| Element | Issue | Severity |
|---------|-------|----------|
| [element] | [what went wrong] | high/medium/low |

## Screenshots

- [list each screenshot path]

## Bugs Found

[BUG-UI-1]: [title] — [description with exact repro steps from agent-browser session]

## Summary

[1-2 sentence summary of the flow outcome]
```

### Step 5: Write Experience Report

Write a standard experience report (same format as ideate.md output) to `docs/internal/reports/iteration-{{ITERATION_NUM}}-report.md`. Triage reads this — format must match:

```markdown
# Kitchen Loop Report - Iteration {{ITERATION_NUM}}

## Scenario: UI Flow — {{FLOW_ID}}
**Date**: [date]
**Mode**: ui
**Tier**: T1 Foundation (UI surface verification)
**Features Exercised**: [features from flow checkpoints]

## What I Did (as a user)
[Browser actions taken, as observed through agent-browser]

## What Worked
[Checkpoints that passed]

## Friction Points
[Failed checkpoints, confusing UI, unexpected behavior]

## Bugs Found
[From evidence.md — with exact repro steps]

## Missing Features
[Gaps identified during the flow]

## Improvements
[UX improvements, better error messages, etc.]

## Tests Added
[Any regression tests written to capture discovered bugs]

## Outcome
[PASS | PARTIAL | FAIL | SKIP — summary]
```

### Step 6: Update State File

Update `.kitchenloop/ui-test-state.json`:
- Move the tested flow from `flows_pending` to `flows_tested`
- Set `last_flow` to the flow id and `last_iteration` to `{{ITERATION_NUM}}`
- If `flows_pending` is now empty after this move: reset (restore all flow IDs to `flows_pending`, clear `flows_tested`)

### Step 7: Screenshot Cleanup

Read `screenshot_retention` from config (default 5). Screenshots are named `{{FLOW_ID}}-{{ITERATION_NUM}}-NN-label.png`. Delete screenshots where the iteration number embedded in the filename is older than `(current_iteration - retention)`:

```bash
RETENTION="$SCREENSHOT_RETENTION"
CUTOFF=$(( {{ITERATION_NUM}} - RETENTION ))
# Delete screenshots for iterations older than CUTOFF
for f in "${SCREENSHOT_DIR}"/*-*.png; do
  # Extract iteration number: second field between first and second dash-separated segments
  # Filename format: FLOW_ID-ITER_NUM-NN-label.png
  iter_in_name=$(echo "$(basename "$f")" | grep -oP '(?<=-)\d+(?=-)' | head -1)
  if [ -n "$iter_in_name" ] && [ "$iter_in_name" -lt "$CUTOFF" ] 2>/dev/null; then
    rm -f "$f"
  fi
done
```

### Step 8: Final Notes

**Do NOT update docs/internal/loop-state.md** — the regress phase handles this.

Be specific in bug reports. Triage will use your experience report to create tickets. Vague reports create vague tickets.
