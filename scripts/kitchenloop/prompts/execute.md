# Kitchen Loop - Phase 3: Execute (Autonomous)

You are running **autonomously** as part of the Kitchen Loop. There is no human operator to interact with. You must make all decisions yourself.

## Autonomous Mode Rules

1. **Do NOT use `EnterPlanMode` or `ExitPlanMode`**. Plan your approach inline, then proceed directly to implementation.
2. **Do NOT use `AskUserQuestion`**. Make reasonable decisions.
3. **Do NOT spawn teams or teammate agents**. Work sequentially, one ticket at a time.
4. **Do NOT use the Write tool to output status messages.** Only use Write/Edit for actual code and documentation files.

## Loop Context
- **Repo root**: {{REPO_ROOT}}
- **Iteration worktree**: {{ITER_WORKTREE}}
- **Iteration number**: {{ITERATION_NUM}}
- **Mode**: {{MODE}}
- **Base branch**: {{BASE_BRANCH}}
- **Important**: You are running inside a git worktree, NOT the main repo directory.
  All file writes go to this worktree. Do NOT `cd` to the repo root.

## Your Task

Run the **execute** phase.

**CRITICAL -- Output a sentinel line as your absolute first action** (before reading files or running any commands):

```
[execute] STARTED -- iteration {{ITERATION_NUM}}, mode={{MODE}}
```

### Step 0: Recover Stale Tickets

Check for tickets marked "in_progress" that don't have an open PR. Move them back to "todo" with a recovery comment ("Recovered by kitchenloop: previous execute run timed out before creating a PR.").

### Step 1: Backpressure Check

Count open PRs on `{{BASE_BRANCH}}`. If > 10, skip execute entirely and log why. If 5-10, focus on smaller, quick-win tickets only.

### Step 2: Pick Top Tickets

{{STARVATION_MODE}}

Query the "todo" tickets and sort them using **strict priority ordering**. Work on tickets in this exact order — never pick a lower-priority ticket while a higher-priority one is available:

| Priority | Pick order | Examples |
|----------|-----------|---------|
| 1. **Urgent/Critical bugs** | Always first | Regressions, broken core functionality, data loss |
| 2. **High priority bugs** | After all critical | Significant bugs affecting common workflows |
| 3. **High priority features** | After all high bugs | Features that unblock other work |
| 4. **Medium priority** | After all high | Moderate bugs, improvements, non-blocking features |
| 5. **Low priority / quick wins** | Fill remaining slots | Polish, small improvements (<30 min) |

Pick 3-5 tickets. Within the same priority tier, prefer quick wins (smallest scope first) to maximize throughput. In your Step 4 summary, state **why** each ticket was chosen over other available tickets.

> **Starvation fallback**: If `STARVATION_MODE` is `true` above and no "todo" tickets are found from the normal ticket source, fall back to the **Backlog**. Run a backlog grooming pass to surface any deferred or deprioritized tickets, then pick from those instead. This prevents the loop from spinning with no work.

### Step 3: Implement Each Ticket

**Before starting**: Read `.kitchenloop/unbeatable-tests.md` to understand what test levels
are expected for this project. When your implementation touches integration points (API
endpoints, database queries, external services, CLI commands), write or extend an **L3
integration test** — not just L1/L2 unit tests. See the quality bar for details.

For each ticket, sequentially:

1. **Read** the ticket fully
2. **Read** relevant code files, docs, and patterns before implementing
3. **Transition** the ticket to "in_progress"
4. **Create a branch** from {{BASE_BRANCH}}: `kitchen/fix-{ticket_id}-{short_desc}`
5. **Implement** the fix or feature
6. **Run linting**: `{{LINT_COMMAND}}`
7. **Run tests**: `{{QUICK_TEST_COMMAND}}`
8. **Commit** with a descriptive message referencing the ticket
9. **Push** and create a PR targeting {{BASE_BRANCH}}
10. **UAT Gate** (if enabled and change touches product code):
    a. Write a test card to `.kitchenloop/uat-cards/{ticket_id}.md` — step-by-step recipe a user would follow to verify the feature works (exact commands, exact expected outputs, no placeholders)
    b. Validate the test card (parse check, no-edit check, no-placeholder check)
    c. Spawn a `uat-evaluator` agent in `isolation: "worktree"` with ONLY the test card (no diff, no ticket, no implementation context)
    d. After evaluator returns, run mechanical integrity check (`git diff` on UAT worktree — any product file modification = EVAL_CHEAT_FAIL)
    e. Attach evidence to PR as comment
    f. Act on verdict: PASS → proceed; PRODUCT_FAIL → keep ticket open, tag PR; UAT_SPEC_FAIL → log, don't block; EVAL_CHEAT_FAIL → flag for review
    See `.claude/skills/kitchenloop-execute/UAT-GATE.md` for the full protocol.
11. **Transition** the ticket to "in_review"
12. **Return** to {{BASE_BRANCH}} in the worktree

### Step 4: Summary

After implementing all tickets, output:
```
Implemented:
  - #123: Fix login timeout (PR #45)
  - #124: Add retry logic (PR #46)
Skipped:
  - #125: Blocked by missing API access
```

## Ticket State Rules

- When you start working on a ticket: move to **"in_progress"**
- When PR is created: move to **"in_review"**
- **NEVER move to "done"** — the PR Manager handles that after merge

## Rules

- Do NOT merge PRs — the Polish phase handles that
- Do NOT use interactive git commands (rebase -i, add -i)
- If a ticket is too complex (> 1 hour), create a partial implementation PR and note what's left
- Always run lint and tests before pushing
- Plan before code: read source files before implementing
- **Do NOT update loop-state.md** — the regress phase handles all loop-state commits
- **Re-read before writing shared files**: If you need to write to any shared state file (coverage matrix, codebase patterns, etc.), re-read it immediately before editing. Other phases may have modified it during this iteration.
