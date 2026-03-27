# Architecture

This document describes the internal architecture of KitchenLoop: the phase
execution model, worktree isolation, artifact persistence, ticket state machine,
trust model, and repo contract.

---

## Phase Diagram

```
                    +------------------+
                    |     BACKLOG      |
                    | scan tickets,    |
                    | check coverage   |
                    +--------+---------+
                             |
                  +----------v-----------+
                  |       IDEATE         |
                  | pick uncovered coord |
                  | generate proposal    |
                  +----------+-----------+
                             |
                  +----------v-----------+
                  |       TRIAGE         |<-----+
                  | self-check           |      |
                  | external review      |      | REDIRECT
                  +---+------+------+----+      |
                      |      |      |           |
               PROCEED|      |      +-----------+
                      |   REJECT (max 2, then tie-breaker)
                      |      |
                      |      +---> back to IDEATE
                      |
                  +---v-----------------+
                  |      EXECUTE        |
                  | create worktree     |
                  | implement changes   |
                  | lint + smoke test   |
                  +----------+----------+
                             |
                  +----------v----------+
                  |       POLISH        |
                  | format, commit      |
                  | push, open PR       |
                  +----------+----------+
                             |
                  +----------v----------+
                  |      REGRESS        |
                  | run full test suite |
                  +---+------------+----+
                      |            |
                   PASS          FAIL
                      |            |
               +------v---+  +----v--------+
               | MERGE PR |  | CLOSE PR    |
               | update   |  | return to   |
               | coverage |  | backlog     |
               +------+---+  +-------------+
                      |
                      v
               next iteration
```

---

## Worktree Isolation Model

Every iteration runs in a disposable git worktree. This provides complete
isolation from the main working tree.

### Directory Layout

```
your-project/                        # main working tree (never modified during iteration)
  .git/                              # shared git object store
  .kitchenloop/
    worktrees/
      iter-42/                       # worktree for iteration 42
        src/                         # full copy of source
        tests/                       # full copy of tests
        ...
    artifacts/                       # permanent iteration records
      iter-42-report.md
      iter-42-proposal.md
    coverage-map.json                # spec surface coverage state
    loop-state.md                    # current loop status (human-readable)
    loop-state.json                  # current loop status (machine-readable)
    backlog.json                     # ticket backlog
  kitchenloop.yaml                   # configuration (in project root)
  src/                               # your source code
  tests/                             # your tests
```

### Worktree Lifecycle

```
1. git worktree add .kitchenloop/worktrees/iter-{N} -b kitchenloop/iter-{N} {base_branch}
2. [Execute phase runs inside the worktree]
3. [Polish phase commits and pushes from the worktree]
4. [Regress phase runs tests inside the worktree]
5a. If PASS: merge PR, then git worktree remove .kitchenloop/worktrees/iter-{N}
5b. If FAIL: close PR, then git worktree remove .kitchenloop/worktrees/iter-{N}
```

The worktree is always removed after the iteration, regardless of outcome.
Stale worktrees from interrupted iterations are cleaned up at the start of the
next run.

### Why Worktrees

- **Isolation**: changes cannot leak into the main tree
- **Speed**: worktrees share the git object store (no full clone)
- **Cleanup**: `git worktree remove` is instant and complete
- **Parallel safety**: multiple worktrees can exist simultaneously (for future parallel mode)

---

## Artifact Persistence

Every iteration produces three artifacts:

### 1. Iteration Report

```
.kitchenloop/artifacts/iter-{N}-report.md
```

Contains:
- Iteration number and timestamp
- Mode (strategy, backtest, etc.)
- Proposal summary
- Triage decision and rationale
- Files created or modified
- Test results (pass count, fail count, skip count)
- Spec surface coordinates covered
- Outcome: MERGED, REJECTED, FAILED, or SKIPPED

### 2. Coverage Map

```
.kitchenloop/coverage-map.json
```

JSON file tracking which spec surface coordinates have been exercised:

```json
{
  "dimensions": ["commands", "flags", "input_types"],
  "total_combinations": 76,
  "covered_combinations": 23,
  "coverage_pct": 30.3,
  "entries": [
    {
      "coordinates": {"commands": "init", "flags": "--verbose", "input_types": "valid_config"},
      "iteration": 1,
      "outcome": "MERGED",
      "pr": "#12"
    }
  ],
  "blocked_combinations": 4,
  "last_updated": "2026-03-10T14:00:00Z"
}
```

### 3. Loop State

```
.kitchenloop/loop-state.md       # human-readable
.kitchenloop/loop-state.json     # machine-readable
```

Current status of the loop:

```markdown
# Loop State

- **Iteration**: 42
- **Mode**: strategy
- **Status**: running (phase: REGRESS)
- **Pass rate**: 97.3% (floor: 95%)
- **Test count**: 312 (baseline: 289)
- **Consecutive failures**: 0
- **Coverage**: 30.3% (23/76)
- **Last merge**: iter-41, PR #87
- **Backlog**: 11 open, 3 blocked
- **Started**: 2026-03-10T10:00:00Z
- **Elapsed**: 4h 23m
```

---

## Ticket State Machine

Tickets track individual work items through the loop.

### States

```
                    +----------+
          +-------->| backlog  |<--------+
          |         +----+-----+         |
          |              |               |
     rejected       prioritized     returned
          |              |          (failed regress)
          |         +----v-----+         |
          |         |   todo   |         |
          |         +----+-----+         |
          |              |               |
          |          picked up           |
          |              |               |
          |    +----+----v------+        |
          |    |  in_progress   |        |
          |    +----+------+----+        |
          |         |      |             |
          |     complete  stuck          |
          |         |      |             |
          |    +----v----+ +---+         |
          +----| in_review|    |         |
               +----+-----+ blocked     |
                    |                    |
               +----+----+              |
               |         |              |
            merged    failed-+-----------+
               |
          +----v-----+
          |   done   |
          +----------+
```

### State Transitions

| From | To | Trigger |
|------|----|---------|
| backlog | todo | Prioritized by Backlog phase |
| todo | in_progress | Picked up by Execute phase |
| in_progress | in_review | PR opened by Polish phase |
| in_review | done | Regression passed, PR merged |
| in_review | backlog | Regression failed, PR closed |
| any | backlog | Triage rejected |
| in_progress | backlog | Execution failed (lint, smoke test) |

### Ticket Schema

```json
{
  "id": "kl-42",
  "title": "Exercise: generate + pdf + git_repo",
  "state": "in_progress",
  "coordinates": {"commands": "generate", "output_formats": "pdf", "input_sources": "git_repo"},
  "created_iteration": 10,
  "attempts": 1,
  "max_attempts": 3,
  "last_failure_reason": null,
  "pr": null
}
```

After 3 failed attempts (`max_attempts`), a ticket is moved to `blocked` state
and requires manual intervention.

---

## Trust Model

### Role Separation

```
+---------------------+         +---------------------+
|    IMPLEMENTER      |         |     REVIEWER        |
|  (Claude Code)      |         |  (configurable)     |
+---------------------+         +---------------------+
| Has:                |         | Has:                |
|  - Full codebase    |         |  - Proposal only    |
|  - Git history      |         |  - (or PR diff)     |
|  - Test results     |         |                     |
|  - Coverage map     |         | Does NOT have:      |
|                     |         |  - Full codebase    |
| Risks:              |         |  - Git history      |
|  - Tunnel vision    |         |                     |
|  - Over-scoping     |         | Risks:              |
|  - Hallucinated APIs|         |  - Over-conservative|
+---------------------+         +---------------------+
         |                               |
         | proposal                      | PROCEED / REDIRECT / REJECT
         +-------------> TRIAGE <--------+
```

### Review Contract

The reviewer's response MUST follow this format:

```
Line 1: PROCEED | REDIRECT | REJECT
Lines 2+: Rationale (2-5 sentences)
If REJECT: Must include "Salvage path:" line
```

The parser reads only line 1 for the decision. This strict format prevents
ambiguous responses.

### Rejection Handling

- Max 2 rejections per iteration before falling back to tie-breaker
- Tie-breaker priority: (1) largest uncovered dimension > (2) smallest scope >
  (3) oldest ticket
- Reviewer timeout (default 30s) = auto-PROCEED (loop never stalls on reviewer)

---

## Repo Contract

The `paths` section of `kitchenloop.yaml` defines the repo contract — which
parts of the project the loop is allowed to touch.

```yaml
paths:
  source:
    - src/
    - lib/
  tests:
    - tests/
  docs:
    - docs/
  exclude:
    - .env
    - credentials/
    - migrations/
    - vendor/
    - node_modules/
```

### Rules

1. **Execute phase** may only create or modify files under `paths.source` and
   `paths.tests`
2. **Files in `paths.exclude`** are never read, modified, or deleted
3. **Files outside all configured paths** are read-only (the loop can read them
   for context but cannot modify them)
4. **`kitchenloop.yaml` itself** is never modified by the loop
5. **`.kitchenloop/` directory** is managed exclusively by the framework

Violations of the repo contract cause the iteration to fail immediately. The
worktree is discarded and the violation is logged in the iteration report.
