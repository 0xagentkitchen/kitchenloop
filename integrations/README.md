# Integrations

KitchenLoop works out of the box with **GitHub Issues** for ticketing and **GitHub Actions** for CI. No extra setup needed — `gh` handles everything.

These integrations let you swap in more powerful tools when you're ready.

## Available Integrations

| Integration | Replaces | What You Get |
|-------------|----------|-------------|
| [Linear](linear/) | GitHub Issues | Rich project management — priorities, blocking relationships, team workflows, custom labels (Discussion, Moonshot), cycle tracking |
| [CodeRabbit](coderabbit/) | Manual PR review | Automated AI code review on every PR — the loop resolves review comments autonomously |
| [Discussion Manager](discussion-manager/) | Single-model decisions | Multi-AI debates (Gemini + Codex + Claude) for architecture decisions, feature design, and "should we build this?" questions |

## How Integrations Work

Each integration folder contains:
- `README.md` — Setup guide, what it enables, configuration reference
- Any additional config files or scripts needed

Integrations are **additive** — they enhance the loop, they don't replace the core. You can adopt them independently in any order.

## The Default Stack

Without any integrations, KitchenLoop uses:

```
Ticketing:    GitHub Issues (label-based state machine)
CI:           GitHub Actions (or any CI that reports status on PRs)
Code Review:  Claude Code (the implementing agent reviews its own work)
Decisions:    Single-model (Claude makes all judgment calls)
```

This is sufficient for small-to-medium projects. The integrations become valuable when:
- Your backlog grows beyond what label-based tracking handles well → **Linear**
- You want independent code review that catches what the implementing agent misses → **CodeRabbit**
- You face decisions where one model's blind spots could waste iterations → **Discussion Manager**
