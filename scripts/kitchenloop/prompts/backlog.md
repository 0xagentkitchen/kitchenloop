# Kitchen Loop - Backlog Grooming (Autonomous)

You are running **autonomously** as part of the Kitchen Loop. There is no human operator to interact with. You must make all decisions yourself.

## Autonomous Mode Rules

1. **Do NOT use `EnterPlanMode` or `ExitPlanMode`**. Proceed directly.
2. **Do NOT use `AskUserQuestion`**. Make reasonable decisions.
3. In autonomous mode, you ARE the approver. Evaluate and promote without waiting for confirmation.
4. **Do NOT use the Write tool to output status messages.** Never create files with names like "=== Done ===", "Exit code:", etc. Only use Write/Edit for actual code and documentation files.

## Context
- Iteration: {{ITERATION_NUM}}
- Working directory: {{ITER_WORKTREE}}
- Base branch: {{BASE_BRANCH}}

## Your Task

**CRITICAL -- Output a sentinel line as your absolute first action** (before reading files or running any commands):

```
[backlog] STARTED -- iteration {{ITERATION_NUM}}
```

Run the **backlog grooming** phase:

### Step 1: Category-Aware Backpressure Check

Count tickets currently in "todo" state **by category**:

- If todo has **8+ total AND balanced categories**: skip grooming (report count and stop)
- If todo has **8+ total but missing categories**: continue, but ONLY add tickets for deficient categories
- If todo has **<8 total**: full grooming pass (all categories)

### Step 1.5: Abandoned Fix PR Scan

Scan for tickets whose fix PRs were closed without merging — these bugs are still live:

```bash
gh pr list --state closed --limit 50 \
  --json number,title,body,state,mergedAt \
  --jq '.[] | select(.mergedAt == null)'
```

For each closed-not-merged PR:
1. Extract the ticket ID from the PR title/body (look for #N references)
2. Check if the ticket is still open (todo/in_progress/in_review)
3. If yes: promote back to "todo" with comment: "Fix PR #N was closed without merging. Bug is still live on main. Re-promoting for execution."
4. If the ticket was already closed: reopen it

This prevents bugs from going unfixed when AI-generated fix PRs are silently abandoned.

### Step 2: Scan and Evaluate

Scan all tickets in "backlog" state. For each ticket, evaluate:

1. **Urgency** (1-5): Is this blocking other work? Is it a regression? Time-sensitive?
2. **Accessibility** (1-5): Can it be implemented with existing code? Dependencies available?
3. **Impact** (1-5): How many users/features does this affect? Does it improve the testing pipeline?

Score = Urgency + Accessibility + Impact (max 15)

### Step 3: Category Balance

Ensure the todo queue has a healthy mix using this composition:

| Category | Target | Purpose |
|----------|--------|---------|
| **Bug** | 2-3 | Fix what's broken — highest reliability impact |
| **Feature** | 1-2 | Expand capabilities, exercises new spec surface |
| **Improvement** | 1-2 | Polish and momentum |
| **Exploration** | 0-1 | Creative stress-testing, coverage discovery |

### Step 4: Execute Promotions

Move the top-scoring tickets to "todo" state until the queue reaches 5-8 tickets:
1. Transition state from "backlog" to "todo"
2. Add a comment: "Promoted to todo by Kitchen Loop backlog grooming (iteration {{ITERATION_NUM}})"

### Step 5: Summary

Output:
```
Backlog grooming complete:
  Scanned: N backlog tickets
  Promoted: M tickets to todo
  Todo queue: X tickets (target: 5-8)
  Promoted:
    - #123: Fix login timeout (bug, score: 13)
    - #124: Add retry logic (improvement, score: 11)
```

## Rules

- Do NOT create new tickets — only promote existing ones from backlog
- Do NOT modify ticket content — only change state
- If the backlog is empty, output: "Backlog empty — ideate phase will create new scenarios"
