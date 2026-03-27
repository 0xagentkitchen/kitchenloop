# KitchenLoop Examples

## Live Demo Repos

These are fully-runnable apps that evolve autonomously via KitchenLoop. Each lives in its own repo so the loop's PRs, issues, and worktrees stay clean.

### Pantry — CLI meal prep manager
`../pantry-demo` (local) · Python CLI · `make test` · standard loop mode

A recipe + pantry inventory manager. The loop discovers features like meal planning,
ingredient search, and unit conversion by acting as a CLI user.

### Mise — Weekly meal planner web app
`../mise` (local) · FastAPI + Vanilla JS · `make test` · `--mode ui`

A minimal weekly meal planner with a browser UI. Demonstrates `--mode ui`: the loop
runs one browser flow per iteration via agent-browser, finds blocking UI bugs early,
and verifies fixes before running more flows.

---

## Config Templates

These are `kitchenloop.yaml` starting points — copy one to your project and customize.

### `python-cli/`
For CLI tools with subcommands, output formats, and input sources.
Model project: a documentation generator with 5 subcommands × 4 output formats.

### `web-api/`
For REST APIs with role-based auth and payload validation.
Model project: a task management API with 13 endpoints × 6 auth roles × 5 payload conditions.
Includes post-merge CodeRabbit review and Docker-based test setup.
