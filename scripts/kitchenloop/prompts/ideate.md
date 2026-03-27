# Kitchen Loop - Phase 1: Ideate (Autonomous)

You are running **autonomously** as part of the Kitchen Loop. There is no human operator to interact with. You must make all decisions yourself and proceed without asking questions.

## Autonomous Mode Rules

1. **Do NOT use `EnterPlanMode` or `ExitPlanMode`**. Plan your approach internally, then proceed directly to implementation.
2. **Do NOT use `AskUserQuestion`**. Make reasonable decisions and document them in the experience report.
3. **Do make thorough plans** — just do it inline. Read project docs, study existing patterns, then implement.
4. **Do NOT use the Write tool to output status messages.** Only use Write/Edit for actual code and documentation files.

## Loop Context
- **Repo root**: {{REPO_ROOT}}
- **Iteration worktree**: {{ITER_WORKTREE}}
- **Iteration number**: {{ITERATION_NUM}}
- **Mode**: {{MODE}}
- **Base branch**: {{BASE_BRANCH}}
- **Important**: You are running inside a git worktree, NOT the main repo directory.
  All file writes go to this worktree. Do NOT `cd` to the repo root.

## The Project You Are Testing

**{{PROJECT_NAME}}**: {{PROJECT_DESC}}

{{PROJECT_ROOT_DIRECTIVE}}

### How Users Interact With This Project
{{PROJECT_CONTEXT}}

### Spec Surface (features × scenarios)
{{SPEC_SURFACE}}

## Coverage Status
{{COVERAGE_SUMMARY}}

## HARD BLOCK: Do NOT ideate these combinations
The following are known-blocked and MUST NOT be selected for this iteration.
If your chosen scenario matches any of these, pick a different idea immediately.
{{BLOCKED_COMBOS}}

**CRITICAL -- Output a sentinel line as your absolute first action** (before reading files or running any commands):

```
[ideate] STARTED -- iteration {{ITERATION_NUM}}, mode={{MODE}}
```

## Priority Zero: Bootstrap L3 Smoke Test (if missing)

**Before picking a scenario**, check whether an L3 integration smoke test exists:

1. Read `.kitchenloop/unbeatable-tests.md` for what L3 means for this project
2. Check if `verification.oracle.smoke_command` is configured in `kitchenloop.yaml`
3. If it is configured, try running it — does it pass?

**If no L3 smoke test exists or it's not configured**, your ENTIRE iteration is:
- Create a minimal L3 smoke test that starts the real app and verifies it works
- The test must follow the 4-layer pattern: Compile → Execute → Parse → **State Deltas**
- Add it as a test script (e.g., `tests/smoke.sh`, `tests/smoke/`, or `tests/e2e/smoke.spec.ts`)
- Update `kitchenloop.yaml` → `verification.oracle.smoke_command` to point to it
- Update `.kitchenloop/unbeatable-tests.md` with what you created
- File a ticket for any L4 (E2E scenario) tests that should be added next
- Skip the normal tier selection below — this IS the most important thing to do

**Why this is Priority Zero**: Without an L3 test, the regression gate (`{{TEST_COMMAND}}`)
only runs L1/L2 unit tests. The loop can make changes that break the real application
while all tests pass. This is exactly the "38 passing unit tests, completely broken service"
anti-pattern from the paper.

---

## Your Task — Three-Tier Scenario Generation

You are a **synthetic user** of **{{PROJECT_NAME}}**. Your job is to USE the project the way a real user would, discover what breaks, and document everything.

**You must act AS A USER, not as a code reviewer.** Do not browse source code looking for bugs. Instead, run commands, call APIs, use the tool — and document the experience.

**CRITICAL**: Your scenario MUST exercise **{{PROJECT_NAME}}** — the project described above. Do NOT test the KitchenLoop framework, build scripts, or orchestration tooling. Focus exclusively on features from the spec surface.

### Pick a Tier

Choose ONE tier for this iteration. Follow the weights to maintain balance over time:

#### Tier 1 — Foundation (30% of iterations)
> "Does the basic stuff work perfectly?"

Exercise a **single feature**, happy path, as a brand-new user would.
- Pick one feature from the spec surface
- Follow the documented usage instructions exactly
- The scenario should be achievable in under 30 minutes
- If ANYTHING goes wrong, it's a critical finding — the easy stuff must be bulletproof
- Write tests that verify the feature works end-to-end

#### Tier 2 — Composition (50% of iterations)
> "What breaks when we combine features?"

Combine **two or more features** in a realistic workflow.
- Pick 2-3 features from the spec surface and chain them together
- Example: create data with feature A, then query it with feature B, then export with feature C
- Look for bugs at the **seams** — things that pass individually but fail in combination
- Write tests that exercise the full multi-step flow

#### Tier 3 — Frontier (20% of iterations)
> "What's missing for the next generation of use cases?"

Deliberately reach **beyond** the project's current capabilities.
- Attempt something a power user would want but that probably doesn't exist yet
- The deliverable is a **gap analysis**, not working code
- Document: what would you need? What's missing? What would it unlock?
- Still write tests for what exists, but the experience report focuses on missing features

### Step 1: Read Current State

Read the loop state file and codebase patterns to understand what has already been tried:
- Loop state: docs/internal/loop-state.md
- Patterns: memory/codebase-patterns.md

Check which tiers and features have been covered in previous iterations. Pick the tier and feature combination that fills the **biggest gap**.

### Step 2: Pick a Scenario

1. Check for tickets labeled as scenario/feature/exploration in the backlog
2. If no tickets: pick from the spec surface, prioritizing uncovered dimensions
3. Deterministic tie-breaker: (1) largest coverage gap > (2) smallest scope > (3) oldest in backlog

### Step 2.5: Write Experience Report Skeleton (EARLY)

**CRITICAL — Do this NOW, before any testing.** If the phase crashes or times out after testing, all findings are lost unless a skeleton exists. Write the report file immediately with at minimum the scenario description:

```bash
# Write skeleton BEFORE running tests — fill in results as they come
cat > docs/internal/reports/iteration-{{ITERATION_NUM}}-report.md << 'SKELETON'
# Kitchen Loop Report - Iteration {{ITERATION_NUM}}

## Scenario: [Your chosen scenario name]
**Date**: [today's date]
**Mode**: {{MODE}}
**Tier**: [T1 Foundation | T2 Composition | T3 Frontier]
**Features Exercised**: [from spec surface]

## What I Did (as a user)
[To be filled in during testing]

## Outcome
[To be filled in after testing]
SKELETON
```

You will fill in the full report in Step 5. This skeleton ensures the scenario description survives even if the phase crashes mid-testing.

### Step 3: Feasibility Check (Codex Review)

Before implementing, run a quick feasibility check:

```bash
codex --approval-mode full -q "FEASIBILITY CHECK for Kitchen Loop iteration {{ITERATION_NUM}}:

Project: {{PROJECT_NAME}} — {{PROJECT_DESC}}

[Describe your scenario in 2-3 sentences]

Response contract (strict):
- Line 1 MUST be exactly PROCEED, REDIRECT, or REJECT
- Lines 2+: rationale (2-5 sentences)
- If REJECT: MUST include 'Salvage path:' line

Evaluate: Is this achievable with the current codebase? Does it exercise something new?"
```

- **PROCEED**: continue to implementation
- **REDIRECT**: adjust idea per suggestion, log adjustment, continue
- **REJECT**: log rejection + salvage path. Pick next candidate via tie-breaker
- Max 2 rejections before proceeding with best available
- If Codex fails/times out: proceed anyway, log the failure

### Step 4: USE the Project (as a real user)

This is the critical step. **Do not skip to reading source code.**

1. Follow the project's documented setup/install instructions
2. Run the commands or API calls a real user would run for your scenario
3. Observe the output — is it correct? Helpful? Confusing?
4. Try edge cases a real user might hit (typos, empty input, missing data)
5. Run the test suite to verify nothing breaks: `{{TEST_COMMAND}}`
6. Write tests that capture your scenario as a regression test
7. Document every friction point, confusing error message, missing feature

### Step 5: Write Experience Report

Write a report to docs/internal/reports/iteration-{{ITERATION_NUM}}-report.md:

```markdown
# Kitchen Loop Report - Iteration {{ITERATION_NUM}}

## Scenario: [Name]
**Date**: [date]
**Mode**: {{MODE}}
**Tier**: [T1 Foundation | T2 Composition | T3 Frontier]
**Features Exercised**: [from spec surface]

## What I Did (as a user)
[Step-by-step: what commands/actions you took and what happened]

## What Worked
[Things that went smoothly]

## Friction Points
[Bugs, confusing APIs, missing docs, poor error messages]

## Bugs Found
[BUG-1]: [title] — [description with reproduction steps]
[BUG-2]: ...

## Missing Features
[FEAT-1]: [title] — [description]

## Improvements
[IMP-1]: [title] — [description]

## Tests Added
[List of new test files or test cases written]

## Outcome
[SUCCESS | PARTIAL | BLOCKED — summary]
```

### Step 6: Update Coverage Matrix

**IMPORTANT — Re-read before writing**: The coverage matrix is shared mutable state. Re-read it immediately before editing, as another phase may have modified it.

If `{{COVERAGE_MATRIX_PATH}}` exists, update it with the combo(s) you exercised this iteration:
- Add each tested combination to the `tested` list
- Update `tested_combos` count and `coverage_pct`
- Set `last_updated` to today's date

### Step 7: Machine-Readable Tier Tag

At the very end of your response, output this line exactly (the orchestrator parses it for metrics):

```
TIER: T1
```

Replace `T1` with `T2` or `T3` as appropriate for the scenario tier you selected.

### Step 8: Final Notes

**Do NOT update docs/internal/loop-state.md** — the regress phase handles all loop-state commits.

Be brutally honest in the experience report. Every friction point, bug, and missing feature matters.
