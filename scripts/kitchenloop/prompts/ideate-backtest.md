# Kitchen Loop - Phase 1: Ideate Backtest (Autonomous)

You are running **autonomously** as part of the Kitchen Loop in **backtest mode**. There is no human operator to interact with. You must make all decisions yourself and proceed without asking questions.

## Autonomous Mode Rules

1. **Do NOT use `EnterPlanMode` or `ExitPlanMode`**. Plan your approach internally, then proceed directly.
2. **Do NOT use `AskUserQuestion`**. Make reasonable decisions and document them in the experience report.
3. **Do make thorough plans** — just do it inline. Read docs, study test patterns, then implement.
4. **Do NOT use the Write tool to output status messages.** Only use Write/Edit for actual code and documentation files.

## Loop Context
- **Repo root**: {{REPO_ROOT}}
- **Iteration worktree**: {{ITER_WORKTREE}}
- **Iteration number**: {{ITERATION_NUM}}
- **Mode**: {{MODE}}
- **Base branch**: {{BASE_BRANCH}}
- **Important**: You are running inside a git worktree, NOT the main repo directory.
  All file writes go to this worktree. Do NOT `cd` to the repo root.

## Goal

**As a user, try to use the testing capabilities. If something doesn't work, implement what's missing.**

The scenario you implement is the **vehicle**, not the destination. Keep it simple. The real test is whether the testing tools work correctly, produce useful output, and have acceptable UX.

## HARD BLOCK: Do NOT ideate these combinations
The following are known-blocked and MUST NOT be selected for this iteration.
{{BLOCKED_COMBOS}}

## Your Task

**CRITICAL -- Output a sentinel line as your absolute first action** (before reading files or running any commands):

```
[ideate-backtest] STARTED -- iteration {{ITERATION_NUM}}, mode={{MODE}}
```

### Step 1: Read Loop State

Read docs/internal/loop-state.md to understand:
- What iteration we're on
- What scenarios have already been tried
- What testing tools have been tested
- What recurring issues exist

### Step 2: Choose a Testing Angle

Pick ONE of these angles for this iteration:

#### Angle A: Coverage Gap Hunt
- Run the existing test suite and analyze coverage
- Find untested code paths, especially in core modules
- Write tests that cover the gaps

#### Angle B: Edge Case Stress Test
- Pick a well-tested feature and throw unusual inputs at it
- Boundary values, empty inputs, very large inputs, unicode, concurrent access
- Document which edge cases are handled vs. which crash

#### Angle C: Test Infrastructure Audit
- Can you run tests in parallel? How fast?
- Are there flaky tests? Can you identify the root cause?
- Is test data well-managed or scattered?
- Are there integration tests that could be unit tests (or vice versa)?

#### Angle D: Regression Scenario
- Pick a recent bug fix or feature change
- Write a regression test that would have caught the issue
- Verify the regression test actually fails on the old code

### Step 3: Codex Idea Review (Feasibility Check)

Before implementing, submit the idea to Codex for a quick feasibility check:

1. Write idea JSON to `notes/.tmp/ideate-idea.json`:
```json
{
  "name": "Test Scenario Name",
  "angle": "coverage_gap|edge_case|infrastructure|regression",
  "target_modules": ["module1", "module2"],
  "gap_filled": "Description of what this tests",
  "mode": "backtest"
}
```

2. Run Codex review (30s timeout):
```bash
IDEA_JSON=$(cat notes/.tmp/ideate-idea.json)

# NOTE: Use gtimeout on macOS, timeout on Linux. If neither is available, skip the review.
cat <<PROMPT_EOF | timeout 30 codex exec --output-last-message notes/.tmp/ideate-review.md -
You are reviewing a testing scenario idea for an autonomous improvement loop.

MODE: backtest (exercise the testing pipeline, not features)

IDEA:
${IDEA_JSON}

RESPONSE FORMAT (strict):
Line 1: Exactly one of PROCEED, REDIRECT, or REJECT (nothing else on this line)
Lines 2+: Your rationale (2-5 sentences)
If REJECT: You MUST include a "Salvage path:" line

Evaluate: Is this achievable? Will it find real gaps? Not too trivial, not too ambitious?
PROMPT_EOF
```

3. Parse result: PROCEED / REDIRECT / REJECT (same rules as strategy mode)
4. Max 2 rejections before proceeding with best available
5. If Codex fails/times out: proceed anyway, log the failure

### Step 4: Implement Tests

Keep the scenario **simple**. The scenario is the vehicle, testing is the destination.

1. Write the test(s) or test tooling improvement
2. Run them and capture the output
3. Document each test tool's results

**For each test tool / test command exercised, document:**
- Did it run? (Y/N)
- Exit code
- Errors (full stderr if failed)
- Output quality (useful? clear?)
- UX assessment (confusing flags? bad error messages?)
- What's missing?

### Step 5: Fix Broken Tools

This is the **key difference from strategy mode**. If a test tool is broken:

1. Investigate the root cause
2. Try to fix it right there — minimal, targeted fix (not a refactor)
3. Re-run the tool after fixing
4. Document: what was broken, what you fixed, did the fix work?

If the fix is too large (>30 min estimate), document it and create a ticket instead.

### Step 6: Write Experience Report

Create a report at docs/internal/reports/iteration-{{ITERATION_NUM}}-backtest-report.md:

```markdown
# Kitchen Loop Report - Iteration {{ITERATION_NUM}} (Backtest Mode)

## Testing Angle: [Name]
**Date**: [date]
**Mode**: Backtest
**Target Modules**: [modules tested]
**Test Commands Exercised**: [list]

## Approach
[Brief — the scenario is the vehicle, not the focus]

## Test Tool Results

### [Test Command 1]
- **Status**: PASS/FAIL/SKIPPED
- **Command**: `[exact command run]`
- **Exit code**: [code]
- **Output**: [description of what was produced]
- **Issues**: [any errors or gaps]
- **Fix attempted**: [yes/no, what was done]

### [Test Command 2]
...

## Testing Gaps Found

### Missing Coverage
[Untested paths discovered]

### Test Infrastructure Issues
[Broken tools, confusing output, missing docs]

### Flaky Tests
[Tests that pass/fail non-deterministically]

## Fixes Applied During This Iteration
[List of code changes made to fix broken tools]

## Recommendations
[Ordered list of what should be fixed/improved, by priority]
```

### Step 7: Update Loop State

**Do NOT update docs/internal/loop-state.md** — the regress phase handles all loop-state commits.

## What to Look For

- Missing test coverage for core modules
- Test data management issues (hardcoded paths, stale fixtures)
- Flaky test root causes (timing, ordering, shared state)
- CLI/tool UX issues (confusing flags, bad error messages, missing --help)
- Test types that are missing entirely (no integration tests, no property tests)
- Performance bottlenecks in the test suite
- Missing test outputs (no coverage reports, no JUnit XML)

## Important Notes

- Do NOT modify application code during test tool runs — only fix broken test tools in Step 5
- If a tool is completely non-functional (crashes on import, missing module), that's the most valuable finding
- Time each tool run. Test performance is a UX metric.
- Be brutally honest. Sugar-coating defeats the purpose.
