# KitchenLoop

Autonomous improvement loop for any codebase, powered by Claude Code.

## Project Structure

- `scripts/kitchenloop/kitchenloop.sh` — Main loop orchestrator (bash)
- `scripts/kitchenloop/prompts/` — Phase prompts (ideate, execute, triage, polish, regress, backlog)
- `scripts/kitchenloop/lib/` — Config loader (`config.sh`), path resolver (`paths.sh`), ticket adapter (`tickets.sh`)
- `scripts/pr-manager/` — Automated PR lifecycle management
- `scripts/ai-discussion/discuss.py` — Multi-AI discussion orchestrator (Python 3.10+)
- `lib/` — Shared bash libraries (config, paths, tickets)
- `skills/` — Source skill definitions (copied to `.claude/skills/` by init)
- `templates/` — Template files for new project scaffolding
- `examples/` — Example configs for Python CLI and Web API projects
- `whitepaper.md` — Framework design, method, and validation (repo root)
- `docs/howto.md` — Operator manual for running KitchenLoop
- `kitchenloop.example.yaml` — Example configuration

## Key Concepts

- **Spec surface**: The matrix of features x platforms x actions your product claims to support
- **Unbeatable tests**: End-to-end verification against ground truth that the code author cannot fake
- **UAT gate**: Post-implementation adversarial testing by a fresh agent with zero context
- **Drain mode**: Auto-triggered when PR backpressure exceeds threshold
- **Discussion Manager**: Multi-AI deliberation with anti-sycophancy safeguards

## Configuration

All config lives in `kitchenloop.yaml`. The init script generates one interactively.
Config is loaded by `lib/config.sh` using `yq`.

## Running the Loop

```bash
# Single iteration
./scripts/kitchenloop/kitchenloop.sh 1

# 5 iterations in backtest mode
./scripts/kitchenloop/kitchenloop.sh 5 --mode backtest

# Custom base branch
./scripts/kitchenloop/kitchenloop.sh 3 --base develop
```

## Skills

Skills in `.claude/skills/` are auto-discovered by Claude Code. Each skill has a `SKILL.md`.
The prompts in `scripts/kitchenloop/prompts/` are the lightweight versions used by the
orchestrator shell script; the full skills have more detail.

## Code Quality Bar

All code in this repo should be production-ready, project-agnostic, and well-documented.
This is a productization fork — no domain-specific references (Almanak, DeFi, etc.) in
scripts, prompts, or skills. The whitepaper and examples may reference specific domains
for illustration purposes.
