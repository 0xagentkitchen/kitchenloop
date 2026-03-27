# KitchenLoop: Triage

> Phase 2 -- Read experience reports, extract findings, create deduplicated tickets.

## Triggers

- `kitchenloop triage`
- `loop triage`
- `create tickets from report`

---

## Overview

The Triage phase converts the raw friction log from an experience report into
actionable, well-labeled tickets. Every finding becomes exactly one ticket --
no more, no less. Deduplication against existing tickets prevents the backlog
from filling with clones.

---

## Procedure

### Step 1: Read Context

1. Load `kitchenloop.yaml` -- read `paths`, `ticketing`, and `project`.
2. Read loop state at `paths.loop_state` to identify the current iteration number.
3. Read the most recent experience report from `{paths.reports}/experience-report-iter-{N}.md`.
   If a specific report path is provided as an argument, use that instead.

### Step 2: Extract Findings

Parse the **Friction Log** section of the experience report. Each numbered item
becomes a candidate ticket. Categorize each finding:

| Tag in Report | Ticket Category | Label |
|--------------|----------------|-------|
| `[BUG]` | Bug -- something is broken | `{ticketing.github.labels.bug}` |
| `[MISSING]` | Feature -- capability gap | `{ticketing.github.labels.feature}` |
| `[UX]` | Improvement -- works but confusing | `{ticketing.github.labels.improvement}` |
| `[IMPROVEMENT]` | Improvement -- could be better | `{ticketing.github.labels.improvement}` |
| `[EXPLORATION]` | Exploration -- needs investigation | `{ticketing.github.labels.exploration}` |

### Step 3: Deduplicate

Before creating any ticket, search for existing tickets that cover the same issue:

```bash
gh issue list --state open --limit 100 --json number,title,body,labels
```

For each candidate ticket:
1. Search by keywords from the finding title.
2. Check if any open issue covers the same root cause (not just symptoms).
3. If a duplicate exists:
   - Add a comment on the existing issue referencing the new iteration.
   - Do NOT create a new ticket.
4. If a near-duplicate exists (related but not identical):
   - Create the ticket and reference the related issue.

**Abandoned fix PR override**: When you find a duplicate ticket, check if it has a linked fix PR that was closed without merging:

```bash
gh pr view <pr_number> --json state,mergedAt --jq '{state, mergedAt}'
```

If `state == "CLOSED"` and `mergedAt == null`: the fix was abandoned and the bug is still live. **Override the dedup decision**:
- Create a new ticket OR reopen the existing one
- Reference the closed PR: "Previous fix PR #N was closed without merging"
- Set priority to at least the original ticket's priority

### Step 4: Assign Priority

Score each finding on three axes (1-3 scale):

- **Severity**: 1 = cosmetic, 2 = annoying, 3 = blocks usage
- **Frequency**: 1 = rare edge case, 2 = common workflow, 3 = every user hits it
- **Fix effort**: 1 = large (days), 2 = medium (hours), 3 = small (< 1 hour)

**Priority = Severity + Frequency + Fix effort** (max 9)
- 7-9: `priority:high`
- 4-6: `priority:medium`
- 1-3: `priority:low`

### Step 5: Create Tickets

For each new finding (after deduplication), create a ticket:

```bash
gh issue create \
  --title "{category}: {concise description}" \
  --body "$(cat <<'EOF'
## Description
{Detailed description of the finding}

## Root Cause Hypothesis
{Which component or module is responsible. Reference specific architectural
decisions or code paths that lead to this behavior. Be specific about WHY
it fails, not just WHAT fails.}

## File Pointers
- `path/to/file.py:42-58` — {why this location is relevant to the fix}
- `path/to/other.py:100` — {related code that may need changes}

## Reproduction Steps
1. {exact command to set up the scenario}
2. {exact command that triggers the issue}
3. {observe: specific error message or incorrect behavior}

## Expected Behavior
{What should happen}

## Actual Behavior
{What actually happens}

## Acceptance Criteria
- [ ] {specific verifiable condition — e.g. "command X returns exit 0"}
- [ ] {edge case handled — e.g. "invalid input returns error, not crash"}
- [ ] Regression test added covering this scenario

## Source
- Iteration: {N}
- Report: {report_path}
- Scenario: {scenario_description}
- Tier: T{1|2|3}

## Priority Score
- Severity: {1-3}
- Frequency: {1-3}
- Fix effort: {1-3}
- **Total: {sum}/9**
EOF
)" \
  --label "{category_label}" \
  --label "{priority_label}" \
  --label "{ticketing.github.state_labels.todo}"
```

<!-- CUSTOMIZE: Adapt ticket creation for your ticketing provider.
     If using a non-GitHub provider, replace gh issue commands with
     the appropriate API calls (e.g., Linear GraphQL mutations). -->

### Step 6: Summary

Output a triage summary:

```
Triage Summary -- Iteration {N}
================================
Report: {report_path}
Findings extracted: {total}
Tickets created:    {created}
Duplicates skipped: {skipped}
Near-duplicates:    {near_dupes} (linked)

New tickets:
  #{id} -- {title} [{priority}]
  ...
```

Update loop state at `paths.loop_state` with triage results.

---

## Output Contract

1. **One ticket per unique finding** from the experience report
2. **No duplicate tickets** -- checked against all open issues
3. **All tickets labeled** with category, priority, and todo state
4. **Loop state updated** with triage summary

---

## Shared State Safety

**Re-read before writing**: Loop state files (`loop-state.md`, coverage matrix, codebase patterns) are shared mutable state modified by multiple phases. You MUST re-read any shared file immediately before editing it. Do NOT rely on a copy read earlier in this session — another phase may have updated it. If a newer iteration marker already exists, do not overwrite it.

## Configuration Reference

| Config Key | Used For |
|-----------|----------|
| `ticketing.provider` | Ticketing system |
| `ticketing.github.labels` | Category labels |
| `ticketing.github.state_labels.todo` | Initial ticket state |
| `paths.reports` | Where to find experience reports |
| `paths.loop_state` | Loop state file |
| `project.name` | Project context for ticket bodies |
