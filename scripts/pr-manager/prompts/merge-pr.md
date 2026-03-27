# PR Merge Pipeline

You are merging PR #{{PR_NUMBER}}. This extends the prep-pr pipeline with actual merge and cleanup.

## Stages 1-8: Same as prep-pr.md

Run the full 8-stage preparation pipeline first.

## Stage 8.5: Deletion Guard (Defense-in-Depth)

Before merging, verify no files are silently deleted:

```bash
git diff --name-only --diff-filter=D origin/{{BASE_BRANCH}}...HEAD
```

If any files are listed:
1. Check the PR description for explicit documentation of each deletion (e.g., "Removes X because Y").
2. If **any** deletion is undocumented, output `RESULT: NOT_MERGEABLE: undocumented file deletions` and **stop immediately**. Do NOT merge.
3. Only proceed if every deletion is justified in the PR body.

## Stage 9: Merge

If all preparation stages passed (including Stage 8.5):
```bash
gh pr merge {{PR_NUMBER}} --squash --delete-branch --match-head-commit {{VERIFIED_HEAD_SHA}}
```

The `--match-head-commit` flag ensures GitHub only merges the exact commit that was reviewed. If a force-push changed the PR head after the deletion guard ran, the merge will fail safely.

After merge:
- Transition any referenced tickets to "done" state
- Add a comment to each ticket: "Fixed in PR #{{PR_NUMBER}}"

## Stage 10: Cleanup

Remove the worktree:
```bash
git worktree remove .claude/worktrees/pr-{{PR_NUMBER}}
```

## Output

- `MERGED` — PR was successfully merged
- `NOT_MERGEABLE: [reason]` — PR cannot be merged (wrong state, conflicts, etc.)
- `STUCK: [reason]` — PR needs human attention (CI failures, review issues, etc.)
