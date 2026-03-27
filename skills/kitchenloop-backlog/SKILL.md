# KitchenLoop: Backlog

> Scan the backlog, evaluate tickets, promote to todo queue, maintain balance.

## Triggers

- `kitchenloop backlog`
- `groom backlog`
- `promote tickets`

---

## Overview

The Backlog phase keeps the todo queue healthy. It scans all open tickets,
scores them on urgency/accessibility/impact, promotes the best candidates
to the todo queue, and retires stale tickets. The goal is to maintain a
todo queue of 5-8 tickets with good category balance.

---

## Procedure

### Step 1: Read Context

1. Load `kitchenloop.yaml` -- read `ticketing`, `paths`, and `runtime`.
2. Read loop state at `paths.loop_state` for iteration context.
3. Read `paths.patterns` for known patterns that inform prioritization.

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

### Step 2: Inventory Current State

#### Count tickets by state:

```bash
# Todo queue
gh issue list --label "{ticketing.github.state_labels.todo}" --json number,title,labels

# In progress
gh issue list --label "{ticketing.github.state_labels.in_progress}" --json number,title

# In review
gh issue list --label "{ticketing.github.state_labels.in_review}" --json number,title

# Full backlog (unlabeled state)
gh issue list --state open --json number,title,labels,createdAt,body --limit 200
```

<!-- CUSTOMIZE: Adapt inventory queries for your ticketing provider. -->

#### Identify tickets NOT in any KitchenLoop state:
These are backlog tickets that haven't been triaged into the todo queue yet.

### Step 3: Evaluate Drain Mode

Check if drain mode should be activated or deactivated:

- If backlog count > `runtime.drain_threshold`: Enter drain mode.
  In drain mode, only bug-fix tickets are promoted -- no features or improvements.
- If backlog count < `runtime.drain_exit_threshold`: Exit drain mode.
  Resume normal promotion of all categories.

### Step 4: Score Backlog Tickets

For each backlog ticket not yet in the todo queue, calculate a promotion score:

#### Urgency (1-3)
- 3: Bug blocking other work, or referenced in 2+ experience reports
- 2: Bug or missing feature found in recent iteration
- 1: Improvement or old finding

#### Accessibility (1-3)
- 3: Clear fix, small scope, well-defined acceptance criteria
- 2: Moderate scope, may require some investigation
- 1: Large scope, vague requirements, or deep architectural change

#### Impact (1-3)
- 3: Affects core workflow, many users would benefit
- 2: Affects secondary workflow or improves developer experience
- 1: Edge case, cosmetic, or niche scenario

**Promotion score = Urgency + Accessibility + Impact** (max 9)

### Step 5: Category Balance

The todo queue should maintain rough category balance. Target distribution:

| Category | Target % | Min | Max |
|----------|----------|-----|-----|
| Bug fixes | 40% | 2 | 4 |
| Features | 30% | 1 | 3 |
| Improvements | 20% | 1 | 2 |
| Exploration | 10% | 0 | 1 |

When selecting tickets to promote:
1. Sort by promotion score (highest first).
2. If promoting a ticket would exceed the category max, skip to the next
   highest-scored ticket in a different category.
3. Continue until the todo queue reaches 5-8 tickets.

### Step 6: Promote Tickets

For each ticket to promote:

```bash
gh issue edit {ticket_number} --add-label "{ticketing.github.state_labels.todo}"
gh issue comment {ticket_number} --body "Promoted to todo queue by KitchenLoop backlog grooming (iteration {N}). Score: {score}/9 (U:{urgency} A:{accessibility} I:{impact})"
```

### Step 7: Retire Stale Tickets

Identify tickets that should be closed:

- **Old with no activity**: Created more than 10 iterations ago, never promoted.
- **Superseded**: A newer ticket covers the same issue with better context.
- **No longer relevant**: The referenced code or feature has been removed.

For each stale ticket:
```bash
gh issue close {ticket_number} --comment "Closed by KitchenLoop backlog grooming: {reason}"
```

### Step 8: Report

Output a backlog health summary:

```
Backlog Health -- Iteration {N}
================================
Total open tickets:  {total}
Todo queue:          {todo_count} (target: 5-8)
In progress:         {in_progress_count}
In review:           {in_review_count}
Ungroomed backlog:   {backlog_count}
Drain mode:          {yes/no}

Promoted:
  #{id} -- {title} [score: {score}]
  ...

Retired:
  #{id} -- {title} [{reason}]
  ...

Category Distribution (todo queue):
  Bugs:         {count} ({pct}%)
  Features:     {count} ({pct}%)
  Improvements: {count} ({pct}%)
  Exploration:  {count} ({pct}%)
```

Update loop state at `paths.loop_state`.

---

## Output Contract

1. **Todo queue at 5-8 tickets** with category balance
2. **Stale tickets retired** with clear reasons
3. **Loop state updated** with backlog health metrics
4. **Promotion comments** on all promoted tickets

---

## Configuration Reference

## Shared State Safety

**Re-read before writing**: Loop state files (`loop-state.md`, coverage matrix, codebase patterns) are shared mutable state modified by multiple phases. You MUST re-read any shared file immediately before editing it. Do NOT rely on a copy read earlier in this session — another phase may have updated it. If a newer iteration marker already exists, do not overwrite it.

## Configuration Reference

| Config Key | Used For |
|-----------|----------|
| `ticketing.provider` | Ticketing system |
| `ticketing.github.state_labels` | State label names |
| `ticketing.github.labels` | Category label names |
| `runtime.drain_threshold` | When to enter drain mode |
| `runtime.drain_exit_threshold` | When to exit drain mode |
| `runtime.backlog_interval` | How often this phase runs |
| `paths.loop_state` | Loop state file |
| `paths.patterns` | Codebase patterns for context |
