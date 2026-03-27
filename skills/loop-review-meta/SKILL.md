# Loop Review Meta

> Macro analysis across all loop review reports -- trends, recurring themes,
> systemic recommendations.

## Triggers

- `loop review meta`
- `meta analysis`

---

## Overview

Loop Review Meta is a higher-order analysis that reads ALL loop review reports
and identifies patterns that span multiple review periods. While individual
loop reviews catch per-iteration issues, the meta review catches systemic
trends: recurring themes that never get fixed, drift in loop behavior,
effectiveness of self-improvement over time.

---

## Procedure

### Step 1: Gather All Review Reports

1. Load `kitchenloop.yaml` -- read `paths`.
2. List all review reports in `{paths.reports}/`:
   ```bash
   ls {paths.reports}/loop-review-iter-*.md
   ```
3. Read each report. Extract structured data:
   - Iteration range covered
   - Metrics (pass rate, test count, backlog, PRs merged)
   - Finding counts by severity (Blocker, Important, Observation)
   - Recommendations made
   - External auditor results

4. Read loop state at `paths.loop_state` for the full iteration history.

### Step 2: Trend Analysis

#### 2a. Quality Trends

Plot (textually) how key metrics have evolved across all review periods:

- **Pass rate trajectory**: Is it trending up (loop is improving the codebase),
  flat (loop is maintaining), or down (loop is introducing regressions)?
- **Test count trajectory**: Growing (good coverage expansion), shrinking
  (test deletion or skip-creep), or flat?
- **Backlog trajectory**: Growing (more issues found than fixed), shrinking
  (good execution velocity), or stable?

#### 2b. Finding Recurrence

Identify findings that appear across multiple review reports:

1. Cluster findings by theme (e.g., "test coverage gaps", "error handling",
   "documentation drift", "convention violations").
2. For each theme, count how many review periods it appeared in.
3. Flag themes that appear in 3+ reviews as **Systemic Issues**.

#### 2c. Recommendation Follow-Through

For each recommendation made in previous reviews:
1. Was it converted to a ticket?
2. Was the ticket resolved?
3. Did the issue recur after the fix?

Calculate a **recommendation effectiveness rate**:
```
effectiveness = recommendations_resolved / recommendations_made
```

### Step 3: Loop Behavior Analysis

#### 3a. Scenario Coverage Map

Aggregate all scenarios tried across all iterations. Build a coverage matrix:

```
            Feature A  Feature B  Feature C
T1 Happy      [5x]       [3x]       [1x]
T2 Compose    [2x]       [0x]       [1x]
T3 Frontier   [1x]       [0x]       [0x]
```

Identify:
- **Over-exercised areas**: Scenarios repeated many times without new findings.
- **Coverage gaps**: Dimension combinations never tried.
- **Tier imbalance**: Is the loop stuck at T1 and never reaching T2/T3?

#### 3b. Self-Improvement Effectiveness

Score the loop's ability to improve itself over time:

1. **Finding novelty**: Are later iterations finding NEW issues, or re-finding
   the same ones? Calculate the ratio of unique findings to total findings.
2. **Fix durability**: When a bug is fixed, does it stay fixed? Count
   regressions of previously-fixed issues.
3. **Escalation rate**: Is the loop progressing from T1 to T2/T3 scenarios
   over time, or staying flat?
4. **Throughput trend**: Is tickets-per-iteration increasing, stable, or
   declining?

Compute an overall **Self-Improvement Score** (0-100):

```
novelty_score     = unique_findings / total_findings * 25
durability_score  = (1 - regression_rate) * 25
escalation_score  = (t2_t3_ratio) * 25
throughput_score   = normalized_throughput_trend * 25
total = novelty + durability + escalation + throughput
```

<!-- CUSTOMIZE: Adjust the scoring weights and formula based on what
     matters most for your project. A project focused on stability might
     weight durability higher. A project focused on coverage expansion
     might weight escalation and novelty higher. -->

### Step 4: Systemic Recommendations

Based on the analysis, generate systemic recommendations that go beyond
individual ticket fixes:

#### Categories

1. **Process changes**: Adjustments to the loop itself (e.g., "Increase
   review_interval from 3 to 5 -- reviews are not finding enough signal per
   period").

2. **Configuration tuning**: Changes to `kitchenloop.yaml` (e.g., "Add
   {feature_x, feature_y} to spec.blocked until the underlying issue is fixed").

3. **Coverage priorities**: Where the loop should focus next (e.g., "T2
   composition scenarios between auth and payments have never been tested --
   prioritize this").

4. **Architecture signals**: Patterns that suggest deeper issues (e.g.,
   "Error handling findings appear in every review -- consider a systematic
   error handling audit rather than individual fixes").

5. **Loop self-tuning**: Adjustments the loop should make to its own behavior
   (e.g., "Codex is rejecting 60% of scenarios -- either the ideation is
   drifting out of scope or Codex is too conservative. Review rejection logs").

### Step 5: Write Meta Report

Create the report at `{paths.reports}/loop-review-meta-iter-{start}-{end}.md`:

```markdown
# Meta Review: Iterations {first_iter} -- {last_iter}

**Date**: {timestamp}
**Reviews analyzed**: {count}
**Total iterations covered**: {count}

## Executive Summary

{3-5 sentence overview of the loop's trajectory and health}

## Quality Trends

### Pass Rate
{trend description with data points}

### Test Count
{trend description with data points}

### Backlog
{trend description with data points}

## Systemic Issues

{Issues that recur across 3+ review periods}

### {Theme 1}
- **Occurrences**: {count} review periods
- **Examples**: {brief list}
- **Root cause hypothesis**: {analysis}
- **Recommended action**: {action}

### {Theme 2}
...

## Recommendation Follow-Through

- Recommendations made: {total}
- Recommendations resolved: {count}
- Recommendations recurring: {count}
- **Effectiveness rate**: {percentage}%

## Scenario Coverage

{Coverage matrix}

### Coverage Gaps
{List of untested dimension combinations}

### Over-Exercised Areas
{List of scenarios tested 5+ times}

## Self-Improvement Score: {score}/100

| Component | Score | Assessment |
|-----------|-------|------------|
| Finding novelty | {n}/25 | {assessment} |
| Fix durability | {n}/25 | {assessment} |
| Tier escalation | {n}/25 | {assessment} |
| Throughput trend | {n}/25 | {assessment} |

## Systemic Recommendations

{Numbered list, ordered by expected impact}

1. **[{category}]** {recommendation}
2. **[{category}]** {recommendation}
...

## Suggested Config Changes

{Specific kitchenloop.yaml changes, if any}

```yaml
# Example:
spec:
  blocked:
    - "{new blocked combo}"
runtime:
  review_interval: {new value}
```
```

### Step 6: Update Loop State

Update `paths.loop_state` with:
- Meta review timestamp
- Self-improvement score
- Number of systemic issues identified
- Coverage gap count

---

## Output Contract

1. **Meta review report** at `{paths.reports}/loop-review-meta-iter-{start}-{end}.md`
2. **Loop state updated** with meta review metadata
3. **Actionable recommendations** with specific config change suggestions

---

## When to Run

- Automatically every `runtime.review_interval * 3` iterations (i.e., after
  every 3 regular reviews have accumulated).
- On demand when the loop seems stuck or unproductive.
- After a major milestone (e.g., hitting 50 iterations, reaching 95% pass rate).

---

## Configuration Reference

| Config Key | Used For |
|-----------|----------|
| `paths.reports` | Where to find review reports and write meta report |
| `paths.loop_state` | Loop state for iteration history |
| `paths.patterns` | Codebase patterns for trend context |
| `runtime.review_interval` | Frequency of regular reviews (meta = 3x this) |
| `spec.dimensions` | For building coverage matrix |
| `spec.blocked` | Known blocked combos |
| `project.name` | Project context |
