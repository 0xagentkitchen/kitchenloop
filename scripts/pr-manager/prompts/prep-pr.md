# PR Preparation Pipeline

You are preparing PR #{{PR_NUMBER}} for merge. Follow this 8-stage pipeline strictly.

## Stage 1: Safety Checks

Verify:
- [ ] PR targets the correct base branch
- [ ] PR is open and not in draft
- [ ] PR has no merge conflicts
- [ ] PR author is in the allowlist (if configured; empty = trust all)

If any check fails, output `NOT_MERGEABLE: [reason]` and stop.

## Stage 2: Worktree Setup

```bash
git worktree add .claude/worktrees/pr-{{PR_NUMBER}} pr-branch-name
cd .claude/worktrees/pr-{{PR_NUMBER}}
```

## Stage 3: Code Review (Hard Gate)

Run the pr-auditor agent for a deep review:
- Security vulnerabilities
- Logic errors
- Performance issues
- Test coverage gaps

If **critical** issues found: fix them, commit, push. Re-run review.
If issues persist after 2 fix attempts: output `STUCK: critical review issues` and stop.

## Stage 4: External Review — Multi-Model Tribunal

Collect independent reviews from all available external reviewers. Each reviewer
outputs `APPROVE` or `REQUEST_CHANGES` with specific feedback.

### 4a. Codex Review
```bash
codex --approval-mode full -q "Review this PR for correctness, security, and style. Output APPROVE or REQUEST_CHANGES with specific feedback."
```
Timeout: 30s. If timeout or unavailable, record as `UNAVAILABLE`.

### 4b. Gemini Review (if enabled in config: `reviewers.gemini.enabled: true`)
```bash
gemini --approval-mode plan -p "Review this PR diff for: correctness, security, performance. Output APPROVE or REQUEST_CHANGES with specific feedback."
```
Timeout: 60s. If timeout or unavailable, record as `UNAVAILABLE`.

### 4c. Consensus Classification

Combine verdicts from Stage 3 (pr-auditor) and Stage 4a/4b into a tribunal:

| All available reviewers | Classification | Action |
|---|---|---|
| All APPROVE | **CONFIRMED** | Proceed |
| Majority APPROVE | **LIKELY** | Proceed, log dissenting review in PR comment |
| Majority REQUEST_CHANGES | **FLAG** | Add `needs-attention` label, output `STUCK: majority reviewer rejection` |
| All REQUEST_CHANGES | **BLOCKED** | Output `STUCK: unanimous reviewer rejection` |

- When only 2 reviewers available: majority = both must agree.
- When only 1 reviewer available: use that single verdict (no consensus).
- `UNAVAILABLE` reviewers are excluded from the count.
- If REQUEST_CHANGES from any reviewer: attempt to fix the feedback first, then re-evaluate.
  After 2 fix attempts, use the latest verdicts for final classification.

## Stage 5: Branch Update

Update the PR branch with the latest base branch:
```bash
git fetch origin {{BASE_BRANCH}}
git merge origin/{{BASE_BRANCH}} --no-edit
```

If conflicts: resolve them (prefer PR branch intent), commit, push.
If unresolvable: output `STUCK: unresolvable conflicts` and stop.

## Stage 6: CI Wait & Fix (4 rounds max)

Wait for CI checks to complete. If checks fail:
1. Analyze the failure
2. Fix the issue
3. Push and wait again
4. Repeat up to 4 times

If CI still fails after 4 rounds: label PR `needs-attention` and output `STUCK: CI failures`.

## Stage 7: Review Bot Threads (4 rounds max)

Check for unresolved review bot threads (e.g., CodeRabbit). For each:
1. Read the feedback
2. Either fix the issue or reply explaining why it's not applicable
3. Push changes
4. **Poll for re-review** instead of sleeping a fixed duration:

```bash
# Poll every 2 minutes, max 4 polls (8 minutes total)
for i in 1 2 3 4; do
  sleep 120
  unresolved=$(gh pr view {{PR_NUMBER}} --json reviewThreads --jq \
    '[.reviewThreads[] | select(.isResolved == false)] | length')
  [ "$unresolved" -eq 0 ] && break
done
```

Do NOT use a hard `sleep 600` or similar — poll for review status completion.

If threads still unresolved after 4 rounds: continue (non-blocking).

## Stage 8: Final Check

Run one final Codex review (hard gate for critical issues):
```bash
codex --approval-mode full -q "Final review. Is this PR safe to merge? Output APPROVE or REJECT with reason."
```

If REJECT with critical reason: output `STUCK: final review rejection`.

## Output

If all stages pass: output `PREPPED` (ready for merge, but do NOT merge).
Otherwise: output `STUCK: [reason]` or `NOT_MERGEABLE: [reason]`.

## Worktree Cleanup

Always clean up the worktree when done:
```bash
git worktree remove .claude/worktrees/pr-{{PR_NUMBER}}
```
