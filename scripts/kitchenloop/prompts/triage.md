# Kitchen Loop - Phase 2: Triage (Autonomous)

You are running **autonomously** as part of the Kitchen Loop. There is no human operator to interact with. You must make all decisions yourself.

## Autonomous Mode Rules

1. **Do NOT use `EnterPlanMode` or `ExitPlanMode`**. Plan inline and proceed.
2. **Do NOT use `AskUserQuestion`**. Make reasonable decisions and document them.
3. Create all tickets without asking for confirmation. Use your best judgment for priority and labeling.
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

Run the **triage** phase.

**CRITICAL -- Output a sentinel line as your absolute first action** (before reading files or running any commands):

```
[triage] STARTED -- iteration {{ITERATION_NUM}}, mode={{MODE}}
```

### Step 1: Find the Latest Report

Look in docs/internal/reports/ for the most recent iteration report file.

### Step 2: Extract Findings

For each bug, missing feature, improvement, or friction point in the report:
1. Write a clear title (under 80 characters)
2. Write a description with reproduction steps or context
3. Identify the **root cause hypothesis** — which component or file is responsible, and why
4. Include **file pointers** — specific files and line ranges from the experience report or codebase
5. Define **acceptance criteria** — exact conditions for considering the fix verified
6. Write **reproduction steps** — concrete commands or sequence to reproduce the issue
7. Assign a type: `bug`, `feature`, `improvement`, or `exploration`
8. Assign a priority: `critical`, `high`, `medium`, or `low`

### Step 3: Deduplicate (with abandoned-PR override)

Before creating tickets, check existing tickets to avoid duplicates:
- Search for similar titles and descriptions in the existing backlog
- If a duplicate exists, add a comment to the existing ticket instead of creating a new one

**CRITICAL — Abandoned fix PR override**: When you find a duplicate ticket, check if it has a linked fix PR that was **closed without merging**:

```bash
# Check if the existing ticket's fix PR was abandoned
gh pr view <pr_number> --json state,mergedAt --jq '{state, mergedAt}'
```

If `state == "CLOSED"` and `mergedAt == null`: the fix was abandoned and the bug is still live. **Override the dedup decision**:
- Create a new ticket OR reopen the existing one
- Reference the closed PR in the description: "Previous fix PR #N was closed without merging"
- Set priority to at least the original ticket's priority
- This prevents bugs from going unfixed when PRs are silently abandoned

### Step 4: Create Tickets

Create each ticket using the project's ticketing system. Include:
- Clear, descriptive title
- Reproduction steps or context in the body
- Appropriate labels (type + priority)
- Reference to the iteration report
- Set `blocks`/`blockedBy` dependencies between related tickets

### Step 5: Summary

Output all tickets created (or existing ones updated):
```
Created: #123 — "Fix login timeout error" (bug, high)
Updated: #98 — "Add retry logic for API calls" (added iteration {{ITERATION_NUM}} findings)
```

## Rules

- **Do NOT update docs/internal/loop-state.md** — the regress phase handles all loop-state commits
- Use consistent labeling: bug, feature, improvement, exploration
- Priority: Critical = today, High = this week, Medium = this sprint, Low = backlog
