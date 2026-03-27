# Loop Review

> Review N iterations -- read logs, inspect PRs and code, run external auditors,
> write a synthesis report with actionable findings.

## Triggers

- `loop review`
- `review the loop`
- `review iterations`

---

## Overview

Loop Review is a periodic quality audit of the KitchenLoop's recent output. It
reads experience reports, inspects merged PRs and their code changes, optionally
runs external auditors (Codex, Gemini), and produces a durable synthesis report
with findings categorized by severity.

This phase runs every `runtime.review_interval` iterations automatically, or
on demand.

---

## Inputs

- **Iteration range**: Either specified explicitly ("review iterations 10-15")
  or inferred from loop state (last N iterations since the previous review).
- **Configuration**: `kitchenloop.yaml` -- `paths`, `reviewers`, `repo`, `runtime`.

---

## Procedure

### Step 1: Determine Scope

1. Load `kitchenloop.yaml`.
2. Read loop state at `paths.loop_state` to find:
   - The current iteration number.
   - The last iteration that was reviewed.
3. Determine the review range:
   - If called with explicit range (e.g., "iterations 10-15"), use that.
   - Otherwise, review from (last_reviewed + 1) to current iteration.
4. If the range is empty (no new iterations), report "Nothing to review" and exit.

### Step 2: Gather Artifacts

For each iteration in the range, collect:

#### 2a. Experience Reports

Read all reports matching `{paths.reports}/experience-report-iter-{N}.md` for
each N in the range. Extract:
- Scenario description and tier
- Pass/fail status
- Friction log items (count and severity breakdown)

#### 2b. Regression Results

Read loop state entries for each iteration's regression results:
- Pass rate trend
- Test count trend
- Any PAUSED or FLAGGED iterations

#### 2c. PRs and Code Changes

List all PRs merged during the review period:

```bash
# Get merge commits in the date range
git log --merges --oneline --after="{start_date}" --before="{end_date}" {repo.base_branch}

# Or list PRs by merge date
gh pr list --state merged --limit 50 --json number,title,mergedAt,additions,deletions,files,body
```

For each merged PR:
- Read the PR title and body.
- Get the diff summary (files changed, lines added/deleted).
- Check CI status at time of merge.
- Check if any review comments were left (resolved or unresolved).

```bash
gh pr view {pr_number} --json title,body,additions,deletions,files,reviews,comments,statusCheckRollup
```

#### 2d. Tickets Created and Resolved

```bash
# Tickets created during the period
gh issue list --state all --json number,title,labels,createdAt,closedAt --limit 100
```

Filter to the review period. Count:
- Tickets created (inflow)
- Tickets closed (outflow)
- Net backlog change

### Step 3: Internal Analysis

Before running external auditors, perform your own analysis:

#### 3a. Code Quality Assessment

For each merged PR, evaluate:

1. **Correctness**: Does the change actually fix what the ticket described?
2. **Scope discipline**: Does the PR touch only the files needed, or does it
   include unrelated changes?
3. **Test coverage**: Did the PR include tests for the change?
4. **Convention adherence**: Does the code follow project patterns (from
   `paths.patterns`)?
5. **Risk**: Could this change introduce subtle bugs or regressions?

Score each PR: **Good** (no issues), **Acceptable** (minor nits), **Concerning**
(potential problems).

#### 3b. Loop Health Assessment

Evaluate the loop's behavior over the review period:

1. **Scenario diversity**: Were different tiers and dimensions exercised, or did
   the loop get stuck repeating similar scenarios?
2. **Ticket quality**: Are tickets well-described with clear acceptance criteria,
   or are they vague?
3. **Fix rate**: What percentage of tickets created were also resolved in the
   same period?
4. **Regression stability**: Is the pass rate trending up, down, or stable?
5. **Throughput**: How many tickets per iteration? Is it consistent?

### Step 4: External Auditors

Run external auditors based on `reviewers` configuration:

#### 4a. Codex Audit (if `reviewers.codex.enabled`)

For each PR that was scored "Concerning" in Step 3a, or for a random sample of
3 PRs (whichever is more), run a Codex audit:

**Prompt to Codex:**
```
Code review for PR #{number}: {title}

{PR diff or summary}

Evaluate:
1. Does this change introduce any bugs or regressions?
2. Are there edge cases not handled?
3. Is the implementation idiomatic for the project?
4. Any security or performance concerns?

Response format:
- Line 1: APPROVE, COMMENT, or FLAG
- Lines 2+: Findings (one per line, prefixed with severity)
```

Timeout: `reviewers.codex.timeout` seconds. If timeout, record as "Codex: timed out".

#### 4b. Gemini Audit (if `reviewers.gemini.enabled`)

<!-- CUSTOMIZE: Configure Gemini audit prompts and response parsing.
     Gemini is typically used for broader architectural review rather
     than line-by-line code review. -->

If enabled, send a higher-level review prompt to Gemini covering the overall
direction of changes in the review period, not individual PRs.

**Prompt to Gemini:**
```
Architectural review of recent changes to {project.name}.

Summary of changes in iterations {start}-{end}:
{aggregated PR summaries}

Questions:
1. Do these changes move the project in a coherent direction?
2. Are there architectural concerns (coupling, abstraction leaks, etc.)?
3. Any patterns that should be formalized or deprecated?

Response format: Free-form analysis (3-10 paragraphs).
```

Timeout: `reviewers.gemini.timeout` seconds.

#### 4c. PR-Level Auditor

For each merged PR, check for review bot comments (configured via
`pr_manager.review_bot`):

```bash
gh api repos/{owner}/{repo}/pulls/{pr_number}/comments --jq '.[].body'
```

Extract any unresolved review threads or actionable suggestions that were
merged without being addressed.

### Step 5: Synthesize Findings

Combine internal analysis and external auditor results into categorized findings:

#### Severity Levels

| Level | Meaning | Action Required |
|-------|---------|----------------|
| **Blocker** | Bug introduced, regression, or security issue | Must fix before next iteration |
| **Important** | Quality concern, missing tests, pattern violation | Should fix within 2 iterations |
| **Observation** | Style nit, minor improvement opportunity, process note | Track, fix opportunistically |

#### Finding Template

For each finding:
```
### {SEVERITY}: {Title}

**Source**: {PR #N | Experience report iter N | Regression iter N | Auditor: X}
**Category**: {code-quality | test-coverage | loop-behavior | architecture | process}

**Description**: {What was found}

**Evidence**: {Specific file, line, PR, or data point}

**Recommendation**: {What to do about it}
```

### Step 6: Write Report

Create the review report at `{paths.reports}/loop-review-iter-{start}-{end}.md`:

```markdown
# Loop Review: Iterations {start} -- {end}

**Date**: {timestamp}
**Reviewer**: KitchenLoop automated review

## Executive Summary

{2-3 sentence overview of the review period's health}

## Quality Work Performed

**Lead with what the loop accomplished, not just what went wrong.**

### Work Ledger

| Iteration | Bugs Found | PRs Created | PRs Merged | Tests Added | Tickets Created | Tickets Resolved | Notable |
|-----------|-----------|-------------|------------|-------------|-----------------|-----------------|---------|
| {N} | {count} | {count} | {count} | {lines or count} | {count} | {count} | {brief highlight} |
| ... | ... | ... | ... | ... | ... | ... | ... |

### Aggregate Value Summary

{1-2 paragraphs for stakeholders: "In N iterations the loop validated X scenarios, found Y bugs, shipped Z PRs, added W test lines..."}

### Highest-Impact Finds

{Top 2-3 bugs or issues that justify the loop's existence. For each: what was found, how it was caught, what would have happened without the loop.}

### Coverage Expansion

{What moved from untested to validated during this review period? New spec surface combos covered, new test categories added, etc.}

## Metrics

| Metric | Start | End | Trend |
|--------|-------|-----|-------|
| Pass rate | {start_rate}% | {end_rate}% | {up/down/stable} |
| Test count | {start_count} | {end_count} | {delta} |
| Tickets created | -- | {count} | -- |
| Tickets closed | -- | {count} | -- |
| Net backlog | {start_backlog} | {end_backlog} | {delta} |
| PRs merged | -- | {count} | -- |
| Avg PR quality | -- | {Good/Acceptable/Concerning} | -- |

## Scenario Coverage

| Iteration | Tier | Scenario | Result |
|-----------|------|----------|--------|
| {N} | T{1-3} | {desc} | PASS/FAIL |
| ... | ... | ... | ... |

## Findings

### Blockers
{findings or "None"}

### Important
{findings or "None"}

### Observations
{findings or "None"}

## External Auditor Results

### Codex
{summary or "Disabled"}

### Gemini
{summary or "Disabled"}

### Review Bot ({pr_manager.review_bot})
{summary of unresolved threads}

## Loop Behavior Assessment

- **Scenario diversity**: {assessment}
- **Ticket quality**: {assessment}
- **Fix rate**: {percentage}
- **Throughput**: {tickets/iteration}
- **Self-improvement signal**: {is the loop getting better at finding real issues?}

## Recommendations

{Numbered list of actionable recommendations, ordered by priority}

1. {recommendation}
2. {recommendation}
...
```

### Step 7: Create Tickets for Blockers

Any finding categorized as **Blocker** should be automatically converted to a
ticket:

```bash
gh issue create \
  --title "BLOCKER from loop review: {finding title}" \
  --body "{finding description and evidence}" \
  --label "{ticketing.github.labels.bug}" \
  --label "priority:high" \
  --label "{ticketing.github.state_labels.todo}"
```

### Step 8: Update Loop State

Update `paths.loop_state` with:
- Last reviewed iteration number
- Review report path
- Blocker count
- Overall health assessment (healthy / warning / critical)

---

## Output Contract

1. **Review report** at `{paths.reports}/loop-review-iter-{start}-{end}.md`
2. **Blocker tickets created** for any blocker-severity findings
3. **Loop state updated** with review metadata
4. **External auditor results** recorded (even if timed out)

---

## Quality Checklist

Before finalizing the report, verify:

- [ ] Every merged PR in the range was inspected
- [ ] Experience reports were cross-referenced with actual code changes
- [ ] Regression trend was analyzed (not just latest result)
- [ ] At least one external auditor was consulted (if configured)
- [ ] Findings include specific evidence (file paths, PR numbers, data)
- [ ] Recommendations are actionable (not vague "improve X")

---

## Configuration Reference

| Config Key | Used For |
|-----------|----------|
| `reviewers.codex.enabled` | Whether to run Codex auditor |
| `reviewers.codex.timeout` | Codex response timeout |
| `reviewers.gemini.enabled` | Whether to run Gemini auditor |
| `reviewers.gemini.timeout` | Gemini response timeout |
| `pr_manager.review_bot` | Review bot name for thread checking |
| `runtime.review_interval` | How often reviews run |
| `paths.reports` | Where to write the review report |
| `paths.loop_state` | Loop state file |
| `paths.patterns` | Codebase patterns for convention checking |
| `repo.base_branch` | Branch to inspect for merged PRs |
| `project.name` | Project name for auditor prompts |
