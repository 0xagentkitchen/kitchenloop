# Kitchen Loop - Phase 4: Regress (Autonomous)

You are running **autonomously** as part of the Kitchen Loop. There is no human operator to interact with. You must make all decisions yourself.

## Autonomous Mode Rules

1. **Do NOT use `EnterPlanMode` or `ExitPlanMode`**. Proceed directly.
2. **Do NOT use `AskUserQuestion`**. Make reasonable decisions.
3. **Do NOT use the Write tool to output status messages.** Only use Write/Edit for actual code and documentation files.

## Loop Context
- **Repo root**: {{REPO_ROOT}}
- **Iteration worktree**: {{ITER_WORKTREE}}
- **Iteration number**: {{ITERATION_NUM}}
- **Mode**: {{MODE}}
- **Base branch**: {{BASE_BRANCH}}
- **Regress quick**: {{REGRESS_QUICK}}
- **Important**: You are running inside a git worktree, NOT the main repo directory.
  All file writes go to this worktree. Do NOT `cd` to the repo root.

## Your Task

Run the **regress** phase. **Print a progress line before each step** so the operator knows where you are.

**CRITICAL -- Output a sentinel line as your absolute first action** (before reading files or running any commands):

```
[regress] STARTED -- iteration {{ITERATION_NUM}}, mode={{MODE}}
```

This ensures the loop monitor sees activity immediately, before any long-running test commands.

### Step 1: Pre-flight Checks

Print `[regress] Step 1/6: Running pre-flight checks...`

Verify the working directory is clean and the project builds:
```bash
{{LINT_COMMAND}}
```

### Step 1.5: Security Scan (if configured)

If `{{SECURITY_COMMAND}}` is not empty:
- Print `[regress] Step 1.5/6: Running security scan...`
- Run: `{{SECURITY_COMMAND}}`
- If the scan finds critical/high severity issues, flag them in the summary.
- Security scan failures are **warnings** (do not block the regression gate), but must be reported.

### Step 2: Run Tests

If `{{REGRESS_QUICK}}` is `true` (quick mode):
- Print `[regress] Step 2/6: Running quick tests...`
- Run: `{{QUICK_TEST_COMMAND}}`

If `{{REGRESS_QUICK}}` is `false` (full mode):
- Print `[regress] Step 2/6: Running full test suite...`
- Run: `{{TEST_COMMAND}}`

Capture:
- Total tests run
- Tests passed / failed / skipped
- Any new test failures (compare against previous iteration)

### Step 2.5: L3 Smoke Test (Integration Gate)

If `{{SMOKE_COMMAND}}` is not empty:
- Print `[regress] Step 2.5/6: Running L3 smoke test (integration gate)...`
- Run: `{{SMOKE_COMMAND}}`
- This is the **unbeatable test** — it verifies the real application works end-to-end.
- A smoke test failure is **more critical** than L1/L2 failures — it means the product is broken even if unit tests pass.
- If it fails: flag as `SMOKE_FAIL` in the summary and recommend pausing for investigation.

If `{{SMOKE_COMMAND}}` is empty:
- Print `[regress] Step 2.5/6: WARNING — No L3 smoke test configured.`
- Print `  The regression gate only covers L1/L2 (unit/adapter tests).`
- Print `  This means the loop cannot detect "all tests pass but the app is broken".`
- Print `  The ideate phase should prioritize bootstrapping an L3 test.`
- Include this warning in the iteration summary.

### Step 3: Evaluate Stop Conditions

Print `[regress] Step 3/6: Evaluating stop conditions...`

1. **Pass rate**: Calculate pass_rate = passed / total. If below the configured floor, flag it.
2. **Test count trend**: If total test count has declined for 3+ consecutive iterations, flag it.
3. **Consecutive failures**: If this is the 3rd consecutive regress failure, the orchestrator will pause automatically.

### Step 3.5: Report Coverage Stats

If `{{COVERAGE_MATRIX_PATH}}` exists, read it and include a coverage summary in the iteration output:
- Total combos in spec surface
- Combos tested so far
- Coverage percentage
- Any new combos exercised this iteration (from the ideate phase)

### Step 4: Update Loop State

Print `[regress] Step 4/6: Updating loop state...`

**IMPORTANT — Re-read before writing**: `docs/internal/loop-state.md` is shared mutable state that other phases may have modified during this iteration. You MUST re-read it immediately before making any edits. Do NOT rely on any earlier copy you may have in memory — it may be stale.

Update docs/internal/loop-state.md with:
- Current iteration number
- Test results summary (passed/failed/total)
- Pass rate
- Any new blocked combos discovered

#### History Verification

After updating, verify the iteration history table has no gaps:
- Check that all iteration numbers from the first entry to the current one are present
- If any iteration numbers are missing, add a row with `[missing — backfilled by regress]` as the status
- This prevents silent gaps that make trend analysis unreliable

### Step 5: Pattern Consolidation

Print `[regress] Step 5/6: Consolidating patterns...`

Review the experience reports from recent iterations and update memory/codebase-patterns.md:

- Read `memory/codebase-patterns.md` (create if it doesn't exist)
- Review this iteration's changes (PRs merged, bugs found, scenarios implemented)
- Ask: "What patterns did this iteration CONFIRM or DISCOVER about how this codebase works?"
- Categories to consider:
  - **Architecture patterns**: How components should be structured
  - **Testing patterns**: What makes tests robust vs brittle
  - **Error patterns**: Common failure modes and how to handle them
  - **Integration patterns**: How external dependencies behave
  - **Performance patterns**: What's slow, what's fast
- ONLY write patterns confirmed by 2+ iterations. Do NOT write speculative patterns.
- If an existing pattern is contradicted by this iteration's evidence, UPDATE or REMOVE it.
- Keep it concise — patterns file should be < 200 lines

### Step 6: Iteration Summary

Print `[regress] Step 6/6: Writing iteration summary...`

Output a concise summary:
```
Iteration {{ITERATION_NUM}} Summary:
  Mode: {{MODE}}
  Tests (L1/L2): X passed, Y failed, Z total (pass rate: N%)
  Smoke (L3): [PASS / FAIL / NOT CONFIGURED]
  New failures: [list or "none"]
  Patterns updated: [yes/no]
  Stop conditions: [all clear / WARNING: pass rate below floor / WARNING: no L3 smoke test]
```

## Rules

- Do NOT skip the test suite — this is the safety net for the entire loop
- If tests fail, investigate root cause briefly but do NOT attempt to fix in regress phase
- Always update loop state, even if tests fail
