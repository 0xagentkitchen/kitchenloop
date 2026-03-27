# Kitchen Loop - Phase 1: Ideate (Exploration Mode, Autonomous)

You are running **autonomously** in **exploration mode**. The goal is creative, adventurous usage ideas that stress-test the project in unexpected ways. Failures are VALID FINDINGS — they reveal missing features, bad error messages, and edge cases that conservative scenarios never hit.

## Autonomous Mode Rules

1. **Do NOT use `EnterPlanMode`, `ExitPlanMode`, or `AskUserQuestion`**
2. **No Codex feasibility check.** Skip the Codex review entirely. You are the decision-maker.
3. **Failures are successes.** If the scenario crashes, that's a finding. Document what went wrong and why. The experience report is MORE valuable when things break.
4. **Be adventurous.** Try unusual feature combinations, edge-case inputs, complex multi-step workflows, adversarial UX patterns.
5. **Do NOT use the Write tool to output status messages.** Only use Write/Edit for actual code and documentation files.

## Loop Context
- **Repo root**: {{REPO_ROOT}}
- **Iteration worktree**: {{ITER_WORKTREE}}
- **Iteration number**: {{ITERATION_NUM}}
- **Mode**: {{MODE}}
- **Base branch**: {{BASE_BRANCH}}
- **Important**: You are running inside a git worktree. All file writes go here.

## HARD BLOCK: Do NOT ideate these combinations
The following are known-blocked and MUST NOT be selected for this iteration.
Even in exploration mode, these are known infrastructure failures, not interesting edge cases.
{{BLOCKED_COMBOS}}

## Your Task

**CRITICAL -- Output a sentinel line as your absolute first action** (before reading files or running any commands):

```
[ideate-exploration] STARTED -- iteration {{ITERATION_NUM}}, mode={{MODE}}
```

## Exploration Priorities

1. **Untested feature combinations**: Features that work individually but haven't been tested together
2. **Untested configurations**: Try the project with unusual settings, alternate environments
3. **Edge cases**: Zero values, maximum values, empty inputs, unicode, concurrent access, unusual data types
4. **Complex sequences**: Multi-step workflows with 3+ operations, conditional logic, error recovery
5. **Adversarial UX**: Try to use the project in ways a confused/hurried developer might (wrong config, missing fields, wrong order of operations)
6. **Documentation vs. reality**: Does the code actually do what the docs say?

## Workflow

1. Read docs/internal/loop-state.md — understand what's been tried and what hasn't
2. Pick the most adventurous untested combination from the priorities above
3. Attempt it as a real user would
4. **If it fails**: Document the failure mode in detail. What error? What was missing? Was the error message helpful? Could a real user debug this?
5. **If it works**: Great — try to push it further. Can you chain more operations? Try a second iteration with more complexity.
6. Write experience report at docs/internal/reports/iteration-{{ITERATION_NUM}}-exploration-report.md

## Exploration Report Template

```markdown
# Kitchen Loop Report - Iteration {{ITERATION_NUM}} (Exploration Mode)

## Target: [Name]
**Date**: [date]
**Mode**: Exploration
**Features Tested**: [list]
**Adventurousness**: [1-5 scale — how far from the beaten path?]
**Outcome**: WORKED / PARTIAL / FAILED

## What Was Attempted
[Describe the creative/unusual combination and why it was chosen]

## What Happened
[Detailed execution narrative — what worked, what broke, where]

## Findings (ranked by severity)
### Finding 1: [title]
- **Type**: BUG / MISSING_FEATURE / BAD_UX / EDGE_CASE
- **Severity**: Critical / High / Medium / Low
- **Description**: [what happened]
- **Expected**: [what should have happened]
- **Stack trace / error**: [if applicable]

## Error Message Quality
- Were error messages actionable? Could a real user fix this?
- Did silent failures hide real problems?

## Coverage Surface Tested
- [ ] New feature combination
- [ ] New configuration
- [ ] New edge case
- [ ] Multi-step workflow
- [ ] Error handling path
- [ ] Documentation accuracy
```

7. **Do NOT update docs/internal/loop-state.md** — the regress phase handles all loop-state commits.

Be brutally honest in the experience report. Every friction point, bug, and missing feature matters.
