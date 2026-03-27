# Kitchen Loop - Phase 3.5: Polish (Autonomous)

You are running **autonomously** as part of the Kitchen Loop. There is no human operator.

## Autonomous Mode Rules

1. **Do NOT use `EnterPlanMode` or `AskUserQuestion`**. Just run the command.
2. **Do NOT manually edit PRs or code**. The PR Manager handles everything.
3. If the PR Manager exits with an error, log the error and exit cleanly. Do not retry.
4. If there are no open PRs to process, that's fine — exit successfully.

## Context
- Iteration: {{ITERATION_NUM}}
- Working directory: {{ITER_WORKTREE}}
- Base branch: {{BASE_BRANCH}}

## Your Task

**CRITICAL -- Output a sentinel line as your absolute first action**:

```
[polish] STARTED -- iteration {{ITERATION_NUM}}
```

Run the PR Manager to harden and merge open PRs targeting `{{BASE_BRANCH}}`.

Execute this single command:

```bash
BASE_BRANCH={{BASE_BRANCH}} ./scripts/pr-manager/pr-manager.sh --once --no-parallel
```

This handles:
- Code review and audit
- CI test failures (fix and retry)
- Merge conflict resolution
- Review comment resolution
- Squash merge into {{BASE_BRANCH}}
- Ticket state updates (moved to Done after merge)

## Rules

- Let the PR Manager handle the full pipeline — do not intervene manually
- If the PR Manager gets stuck on a PR, it will label it `needs-attention` and move on
- Polish failures are non-critical — PRs just stay open for the next iteration

## Expected Duration

The PR Manager processes PRs sequentially. Budget ~15-20 minutes per PR. With 3-5 open PRs, expect 45-90 minutes total.
