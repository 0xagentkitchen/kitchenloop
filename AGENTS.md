# AGENTS.md - KitchenLoop

## Project Overview

KitchenLoop is an autonomous improvement loop for any codebase, powered by Claude Code. It runs six phases in sequence: **Backlog -> Ideate -> Triage -> Execute -> Polish -> Regress**. Each iteration picks work, implements it, tests it adversarially, and opens a PR -- all without human intervention.

Key concepts:
- **Spec surface** -- the matrix of features x platforms x actions your product claims to support.
- **Unbeatable tests** -- end-to-end verification against ground truth that the code author cannot fake.
- **UAT gate** -- post-implementation adversarial testing by a fresh agent with zero context.
- **Drain mode** -- auto-triggered when PR backpressure exceeds a configured threshold.

## Architecture

```
scripts/kitchenloop/
  kitchenloop.sh          # Main orchestrator (~2000 lines bash). Runs phases via Claude Code subprocess.
  prompts/                # Phase prompts: ideate.md, execute.md, triage.md, polish.md, regress.md, backlog.md
                          # Uses template variables: {{REPO_ROOT}}, {{WORKTREE}}, {{BRANCH}}, etc.
  lib/                    # Internal helpers for the orchestrator

lib/
  config.sh               # yq-based config loader. Reads kitchenloop.yaml.
  paths.sh                # Artifact path resolver. All paths go through here.
  tickets.sh              # Ticket adapter (GitHub Issues / Linear).

scripts/ai-discussion/
  discuss.py              # Multi-AI discussion orchestrator (Python 3.10+). Anti-sycophancy safeguards.

scripts/pr-manager/       # Automated PR lifecycle: create, label, merge, drain.

skills/                   # Source skill definitions. Copied to .claude/skills/ by the init script.
templates/                # Template files for new project scaffolding.
examples/                 # Example configs (Python CLI, Web API).
docs/                     # Whitepaper and internal documentation.
kitchenloop.example.yaml  # Reference configuration.
```

## Worktree Model

All changes happen in **isolated git worktrees**. The orchestrator creates a worktree per iteration, runs every phase inside it, opens a PR from it, and cleans it up afterward. Never modify the main working tree during a loop run.

## Configuration

All config lives in `kitchenloop.yaml` at the target project root. The init script generates one interactively. Config is loaded by `lib/config.sh` using `yq`.

## Running Tests

```bash
make test          # Full test suite
make test-smoke    # Quick smoke tests
make lint          # shellcheck + ruff + yamllint
```

## Code Style

- **Bash**: shellcheck-clean. Quote all variables. Use `local` in functions. Use `set -euo pipefail`.
- **Python**: ruff-formatted. Type hints encouraged.
- **YAML**: yamllint-clean.
- **Prompts**: Markdown with `{{TEMPLATE_VARS}}` for orchestrator substitution.

## Common Tasks

### Adding a new phase

1. Create `scripts/kitchenloop/prompts/<phase>.md` with the prompt template.
2. Wire it into `kitchenloop.sh` in the phase dispatcher (the `case` block that routes phase names to prompt files).
3. Test by running a single iteration: `./scripts/kitchenloop/kitchenloop.sh 1`.

### Adding a new skill

1. Create `skills/<name>/SKILL.md` with the skill definition.
2. Run the init script to copy it to `.claude/skills/`.
3. Skills are auto-discovered by Claude Code from `.claude/skills/`.

### Adding a new example config

1. Create `examples/<name>/kitchenloop.yaml`.
2. Keep it self-contained and domain-illustrative only.

## What NOT To Do

- **Don't modify prompts without testing the full loop.** Prompt changes have cascading effects across all six phases.
- **Don't break init script idempotency.** Running init twice must produce the same result.
- **Don't hardcode paths.** Use `lib/paths.sh` for all artifact and directory resolution.
- **Don't add domain-specific references.** This repo is project-agnostic. No references to specific products, companies, or verticals in scripts, prompts, or skills. Examples and the whitepaper may reference domains for illustration.
- **Don't skip the oracle test suite.** The regress phase exists for a reason -- always validate against unbeatable tests.
