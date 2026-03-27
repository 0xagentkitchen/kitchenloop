# Kitchen Loop - Triage Hook: Bug Reproducer

You are running **autonomously** as a post-triage hook. You will attempt to reproduce bugs found during UI testing to validate them before they enter the backlog as confirmed issues.

## Autonomous Mode Rules

1. **Do NOT use `EnterPlanMode` or `ExitPlanMode`**.
2. **Do NOT use `AskUserQuestion`**.
3. **Ticket state changes are intentional** — see verdict actions below for the exact allowed mutations.

## Loop Context
- **Repo root**: {{REPO_ROOT}}
- **Iteration number**: {{ITERATION_NUM}}

## Your Task

### Step 1: Prerequisites

**Check ticketing provider:**
```bash
PROVIDER="$(yq '.ticketing.provider // "github"' kitchenloop.yaml)"
```
If `PROVIDER` is not `github`: write summary with `SKIP: ticketing provider is $PROVIDER (only github supported)` and exit 0.

**Read labels from config** (never hardcode):
```bash
BUG_LABEL="$(yq '.ticketing.github.labels.bug // "bug"' kitchenloop.yaml)"
TODO_LABEL="$(yq '.ticketing.github.state_labels.todo // "kitchenloop:todo"' kitchenloop.yaml)"
```

**Check agent-browser:**
```bash
if command -v agent-browser 2>/dev/null; then
  AGENT_BROWSER="agent-browser"
elif npx --yes agent-browser --version 2>/dev/null; then
  AGENT_BROWSER="npx agent-browser"
else
  AGENT_BROWSER=""
fi
```

**Read base URL:**
```bash
BASE_URL="$(yq '.ui_tests.base_url' kitchenloop.yaml)"
```

### Step 2: Find This Iteration's Bug Tickets

Do NOT use a time-based heuristic. Instead, scope bugs to this iteration via the evidence file.

1. Read `.kitchenloop/ui-test-runs/` — find the subdirectory for this iteration: `*-{{ITERATION_NUM}}/evidence.md`
2. Extract bug titles from the `## Bugs Found` section of evidence.md
3. For each bug title, find the matching GitHub issue:
   ```bash
   gh issue list --label "$BUG_LABEL" --label "$TODO_LABEL" --state open \
     --json number,title,body --limit 50 \
     | jq --arg title "TITLE_FROM_EVIDENCE" '[.[] | select(.title | contains($title))]'
   ```
4. Collect the matching issue numbers. These are the only issues this hook will touch.

If no evidence file exists for this iteration, write summary with `SKIP: no evidence file found for iteration {{ITERATION_NUM}}` and exit 0.

### Step 3: Attempt Reproduction

For each matched bug ticket:

If `AGENT_BROWSER` is empty: assign verdict `NEEDS_MORE_INFO` (cannot reproduce without browser) and move on.

Otherwise:
1. Read the ticket body for repro steps
2. Run the flow:
   ```bash
   $AGENT_BROWSER open "${BASE_URL}"
   $AGENT_BROWSER wait --load networkidle
   $AGENT_BROWSER snapshot -i
   # Follow repro steps exactly as described in the ticket
   ```
3. If bug observed on first attempt → `CONFIRMED`
4. If bug not observed → retry once:
   - Bug observed on retry → `FLAKY`
   - Bug not observed on retry → `CANNOT_REPRODUCE`
5. If steps are unclear → `NEEDS_MORE_INFO`

### Step 4: Update Tickets Based on Verdict

**CONFIRMED** — Prepend to ticket body:
```bash
gh issue edit <number> --body "**[BUG REPRODUCER]** CONFIRMED — Reproduced in iteration {{ITERATION_NUM}}.

Exact repro steps:
[steps you used in agent-browser]

---
[original body]"
```

**FLAKY** — Prepend to ticket body and add label:
```bash
gh issue edit <number> --body "**[BUG REPRODUCER]** FLAKY — Reproduced on 2nd attempt in iteration {{ITERATION_NUM}}.
Note: may pass on first run, fails on retry.

---
[original body]"
gh issue edit <number> --add-label "flaky"
```

**CANNOT_REPRODUCE** — Add comment, remove from active queue (return to backlog by removing the todo state label — do NOT mark as done):
```bash
gh issue comment <number> --body "[BUG REPRODUCER] CANNOT_REPRODUCE — Could not reproduce in iteration {{ITERATION_NUM}} following the described steps. Returning to backlog pending more information."
gh issue edit <number> --remove-label "$TODO_LABEL"
```

**NEEDS_MORE_INFO** — Add comment only, no state change:
```bash
gh issue comment <number> --body "[BUG REPRODUCER] NEEDS_MORE_INFO — Reproduction steps are unclear or agent-browser was unavailable. Cannot verify without additional context."
```

### Step 5: Write Summary

Write to `.kitchenloop/ui-test-runs/bug-reproduce-{{ITERATION_NUM}}.md`:

```markdown
# Bug Reproducer Summary — Iteration {{ITERATION_NUM}}

**Provider**: github
**Scoped from**: .kitchenloop/ui-test-runs/*-{{ITERATION_NUM}}/evidence.md

| Ticket | Title | Verdict | Notes |
|--------|-------|---------|-------|
| #N | [title] | CONFIRMED | [notes] |
| #M | [title] | CANNOT_REPRODUCE | [notes] |

**Total**: N confirmed, M flaky, K cannot reproduce, J needs-more-info
```

This hook is non-blocking. If anything fails, log it to the summary and exit 0.
