# Integration: CodeRabbit

[CodeRabbit](https://coderabbit.ai) provides automated AI code review on every pull request. The Kitchen Loop's Polish phase resolves CodeRabbit review comments autonomously — creating a feedback loop where code is reviewed and improved without human intervention.

## Why CodeRabbit?

Without external review, the same agent that writes the code also "reviews" it. This creates the same blind-spot problem the UAT Gate addresses for testing: the author unconsciously compensates for gaps they introduced.

CodeRabbit adds an independent reviewer that:
- Catches bugs, security issues, and style violations the implementing agent missed
- Provides specific, actionable comments on the PR diff
- Re-reviews after fixes are pushed (closing the loop)

## Prerequisites

1. Install [CodeRabbit](https://coderabbit.ai) on your GitHub repository
2. CodeRabbit should be configured to auto-review PRs (this is the default)

No API keys or MCP setup needed — CodeRabbit comments on PRs via GitHub, and the loop reads those comments with `gh`.

## Configuration

Update `kitchenloop.yaml`:

```yaml
pr_manager:
  review_bot: "coderabbitai"     # GitHub username of the review bot
  require_ci: true                # Also require CI to pass before merge
  skip_after_failures: 1          # Label PR "needs-attention" after N failed fix attempts
```

## How It Works

The Polish phase already supports CodeRabbit out of the box. Here's the flow:

```
Execute phase creates PR
  → CodeRabbit auto-reviews (comments on the PR)
  → Polish phase reads CodeRabbit comments
  → Polish phase pushes fixes for each comment
  → CodeRabbit re-reviews
  → If all comments resolved + CI green → merge
  → If comments persist after N attempts → label "needs-attention", move on
```

### What the PR Manager Does

The PR manager (`scripts/pr-manager/pr-manager.sh`) handles the CodeRabbit interaction:

1. **Reads review threads**: `gh pr view <number> --json reviewThreads`
2. **Identifies unresolved comments**: Filters for threads by the `review_bot` username that are not resolved
3. **Addresses each comment**: Spawns Claude to read the comment, understand the suggestion, and push a fix
4. **Verifies resolution**: After pushing, checks if CodeRabbit marked the thread as resolved on re-review
5. **Circuit breaker**: After `skip_after_failures` failed attempts on the same PR, labels it `needs-attention` and moves to the next PR

### Review Quality

CodeRabbit catches issues in several categories:
- **Security**: SQL injection, XSS, command injection, hardcoded secrets
- **Correctness**: Off-by-one errors, null pointer risks, race conditions
- **Style**: Naming conventions, dead code, missing error handling
- **Performance**: N+1 queries, unnecessary allocations, missing indexes

The loop resolves ~80% of CodeRabbit comments autonomously. The remaining ~20% are typically architectural suggestions that require human judgment — these get the `needs-attention` label.

## Without CodeRabbit

If you don't want external code review, the loop still works — it just relies on:
- The implementing agent's own review (built into the execute phase)
- CI checks (lint, tests)
- The UAT gate (user-perspective verification)
- The regression oracle (full test suite)

CodeRabbit is additive — it adds another layer of defense, but the loop is safe without it.

## Alternative Review Bots

The PR manager is not CodeRabbit-specific. Any bot that comments on PRs works — just change `review_bot` to its GitHub username:

```yaml
pr_manager:
  review_bot: "github-actions[bot]"  # Or any other review bot
```

The PR manager looks for unresolved review threads from the specified bot username.
