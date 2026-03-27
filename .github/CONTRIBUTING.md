# Contributing to KitchenLoop

Thanks for your interest in KitchenLoop. This guide covers how to report bugs, suggest features, and submit pull requests.

## Getting Started

Read [`CLAUDE.md`](../CLAUDE.md) and [`AGENTS.md`](../AGENTS.md) at the repo root for project structure, key concepts, and agent conventions.

## Development Setup

### Prerequisites

| Tool | Minimum Version |
|------|----------------|
| bash | 4.0+ |
| jq | 1.6+ |
| yq | 4.x |
| gh | 2.x |
| git | 2.30+ |

### Local Setup

```bash
git clone https://github.com/0xagentkitchen/kitchenloop.git
cd kitchenloop
cp kitchenloop.example.yaml kitchenloop.yaml  # edit to taste
```

## Reporting Bugs

Use the [Bug Report](https://github.com/0xagentkitchen/kitchenloop/issues/new?template=bug_report.yml) issue template. Include your environment details, reproduction steps, and relevant logs.

## Suggesting Features

Use the [Feature Request](https://github.com/0xagentkitchen/kitchenloop/issues/new?template=feature_request.yml) issue template. Describe the problem before jumping to a solution.

## Pull Request Process

1. **Open an issue first.** Discuss the change before writing code.
2. **Fork and branch.** Branch from `main` with a descriptive name (e.g., `fix/config-loader-path`).
3. **Follow the code style** (see below).
4. **Write or update tests** if applicable.
5. **Fill out the PR template** completely.
6. **One logical change per PR.** Keep diffs reviewable.

AI-generated contributions are welcome. If your PR was authored or co-authored by an AI tool, note it in the PR description.

## Code Style

### Bash

- Must pass `shellcheck` with zero warnings.
- Use `set -euo pipefail` in all scripts.
- Quote all variables: `"${var}"`, not `$var`.
- Functions use `snake_case`.

### Python

- Formatted and linted with [ruff](https://docs.astral.sh/ruff/).
- Target Python 3.10+.

### YAML

- Validated with [yamllint](https://github.com/adrienverber/yamllint).
- 2-space indentation, no trailing whitespace.

## Commit Messages

Use conventional-style messages:

```
fix: resolve config loader path resolution on Linux
feat: add drain-mode threshold to kitchenloop.yaml
docs: clarify PR process in CONTRIBUTING.md
```

## License

By contributing, you agree that your contributions will be licensed under the same license as the project.
