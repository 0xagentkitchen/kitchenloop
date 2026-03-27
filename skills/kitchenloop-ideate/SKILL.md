# KitchenLoop: Ideate

> Phase 1 -- Brainstorm a usage scenario, implement it, test it, write an experience report.

## Triggers

- `kitchenloop ideate`
- `loop ideate`
- `brainstorm scenario`

---

## Overview

The Ideate phase is where the loop generates new work. You act as a **synthetic
user** of the project: pick a realistic scenario, try to implement it using the
project's public API and tooling, document what works and what doesn't, and
produce a structured experience report that the Triage phase will later convert
into tickets.

---

## Scenario Tiers

### T1 -- Foundation (single feature, happy path)
- Exercise ONE feature from the `spec.dimensions` section of `kitchenloop.yaml`
- Follow the documented happy path exactly
- Goal: verify basics still work, catch regressions early
- Example: "Use the auth module to register a user and log in"

### T2 -- Composition (combine features)
- Exercise TWO OR MORE features together in a realistic workflow
- Goal: catch integration seams, data-flow mismatches, missing error handling
- Example: "Register a user, create a payment, then generate a report"

### T3 -- Frontier (push boundaries)
- Attempt something the project does not explicitly support yet
- Goal: discover missing capabilities, poor error messages, edge cases
- Example: "Use the reports API with a date range that spans a timezone change"

**Tier selection rule**: If the last 3 iterations were all T1, escalate to T2.
If T2 scenarios have high pass rates (>90%), try T3. If T3 keeps failing on the
same root cause, file a blocker ticket and drop back to T2.

---

## Procedure

### Step 1: Read Context

1. Load `kitchenloop.yaml` -- read `spec.dimensions`, `spec.blocked`, `paths`, and `verification`.
2. Read loop state at the path specified by `paths.loop_state`:
   - What iteration number is this?
   - What scenarios were tried in recent iterations?
   - What tiers have been used recently?
3. Read the spec docs listed in `spec.docs` to understand project capabilities.
4. If `paths.patterns` exists, read it for known codebase patterns and pitfalls.

### Step 2: Pick a Scenario

1. Enumerate candidate scenarios by combining `spec.dimensions` values.
2. Filter out any combination listed in `spec.blocked`.
3. Filter out scenarios already covered in the last 5 iterations (from loop state).
4. Apply the tier selection rule above.
5. Pick the scenario that maximizes **coverage novelty** -- prefer untested
   dimension combinations over repeated ones.

<!-- CUSTOMIZE: Add domain-specific scenario selection heuristics here.
     For example, if your project has protocol adapters, prefer untested protocols.
     If it has multi-platform support, alternate between platforms. -->

### Step 3: Codex Feasibility Check

Before implementing, run a feasibility check using the Codex reviewer (if
`reviewers.codex.enabled` is true in `kitchenloop.yaml`):

**Prompt to Codex:**
```
Feasibility check for KitchenLoop scenario.

Scenario: {scenario_description}
Tier: {T1|T2|T3}
Project: {project.name} -- {project.description}

Does this scenario exercise the project's actual design surface?
Is it implementable with existing infrastructure?
Does it provide new coverage (not just repeating prior work)?

Response contract (strict):
- Line 1 MUST be exactly PROCEED, REDIRECT, or REJECT
- Lines 2+: Rationale (2-5 sentences)
- If REJECT: include a "Salvage path:" line
```

**Handle the response:**
- `PROCEED` -- continue with implementation
- `REDIRECT` -- adopt the suggested alternative scenario
- `REJECT` -- use the salvage path, or pick the next candidate using the
  deterministic tie-breaker:
  1. Untested feature > 2. Untested dimension combo > 3. Smallest scope > 4. Oldest in backlog

**Timeout rule**: If Codex does not respond within the configured timeout
(`reviewers.codex.timeout` seconds), proceed with the scenario. The loop must
never stall on a reviewer failure.

**Max rejections**: After 2 rejections, proceed with the best available
candidate per the tie-breaker above.

### Step 4: Implement the Scenario

1. Create the scenario in the directory specified by `paths.scenarios`:
   - File: `{paths.scenarios}/{scenario_slug}/scenario.{ext}`
   - Use the project's native language (`project.language` in config)
2. Follow project conventions:
   - Read any relevant documentation or examples in the repo
   - Use the project's standard import patterns and APIs
   - Include proper error handling
3. Write a test for the scenario:
   - File: `{paths.scenarios}/{scenario_slug}/test_scenario.{ext}`
   - Cover the happy path at minimum
   - For T2/T3, add edge case tests

<!-- CUSTOMIZE: Add domain-specific implementation patterns here.
     For example: "All scenarios must use the standard client initialization pattern"
     or "Scenarios testing the API should use the test server fixture." -->

### Step 5: Run Verification

1. Run the lint command from `verification.oracle.lint_command`.
2. Run the quick test command from `verification.oracle.quick_command`.
3. Run the scenario's own tests.
4. Record all output -- both passes and failures are valuable data.

### Step 6: Write Experience Report

Create the report at `{paths.reports}/experience-report-iter-{N}.md`:

```markdown
# Experience Report: Iteration {N}

## Scenario
- **Tier**: T{1|2|3}
- **Description**: {what was attempted}
- **Dimensions**: {which spec dimensions were exercised}
- **Codex check**: {PROCEED|REDIRECT|REJECT|TIMEOUT}

## Implementation
- **Files created**: {list}
- **Approach**: {brief description}

## Results
- **Lint**: PASS | FAIL ({details})
- **Quick test**: PASS | FAIL ({details})
- **Scenario test**: PASS | FAIL ({details})

## Friction Log
{Numbered list of every point of friction encountered, ordered by severity}

1. **[BUG]** {description} -- {expected vs actual}
2. **[MISSING]** {description} -- {what capability was needed but absent}
3. **[UX]** {description} -- {what was confusing or poorly documented}
4. **[IMPROVEMENT]** {description} -- {what could be better}

## Files Changed
{List of all files created or modified}
```

### Step 7: Update Loop State

Update the loop state file (`paths.loop_state`) with:
- Iteration number incremented
- Scenario description and tier
- Pass/fail status
- Timestamp
- Number of friction items found

---

## Output Contract

At the end of the Ideate phase, the following artifacts MUST exist:

1. **Scenario code** in `{paths.scenarios}/{scenario_slug}/`
2. **Scenario test** in the same directory
3. **Experience report** at `{paths.reports}/experience-report-iter-{N}.md`
4. **Updated loop state** at `{paths.loop_state}`

---

## Anti-Patterns

- **Scope creep**: The scenario must be implementable in a single session. If it
  requires multi-day infrastructure work, it's too big -- split it.
- **Repetition without novelty**: Don't re-test the same dimension combo unless
  a related fix was merged since the last test.
- **Infrastructure building**: Ideate exercises the project AS-IS. Don't build
  new features during ideation -- file tickets for missing capabilities.
- **Ignoring blocked combos**: Always check `spec.blocked` before committing to
  a scenario.

---

## Configuration Reference

All configuration is read from `kitchenloop.yaml`. Key sections:

| Config Key | Used For |
|-----------|----------|
| `spec.dimensions` | Scenario generation candidates |
| `spec.blocked` | Combos to skip |
| `spec.docs` | Docs to read for context |
| `paths.scenarios` | Where to write scenario code |
| `paths.reports` | Where to write experience reports |
| `paths.loop_state` | Loop state file |
| `paths.patterns` | Codebase patterns file |
| `verification.oracle.lint_command` | Lint check |
| `verification.oracle.quick_command` | Quick test |
| `reviewers.codex` | Feasibility reviewer config |
| `project.language` | Implementation language |

## Shared State Safety

**Re-read before writing**: Loop state files (`loop-state.md`, coverage matrix, codebase patterns) are shared mutable state modified by multiple phases. You MUST re-read any shared file immediately before editing it. Do NOT rely on a copy read earlier in this session — another phase may have updated it. If a newer iteration marker already exists, do not overwrite it.
