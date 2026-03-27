# Configuration Reference

All KitchenLoop configuration lives in a single file: `kitchenloop.yaml` at
your project root. This document covers every section, field, default, and
environment variable.

---

## Minimal Configuration

```yaml
project:
  name: my-project
  test_command: "pytest"
```

Everything else has sensible defaults. This is enough to run a loop.

---

## Full Reference

### `project` (required)

Project metadata and build/test/lint commands.

```yaml
project:
  name: my-project                    # required, used in branch names and reports
  language: python                    # optional, auto-detected if omitted
  test_command: "pytest tests/ -v"    # required, must exit 0 on success
  lint_command: "ruff check --fix"    # optional, run during Polish phase
  format_command: "ruff format"       # optional, run during Polish phase
  build_command: "pip install -e ."   # optional, run before tests if present
  smoke_command: "pytest tests/smoke" # optional, fast check during Execute phase
```

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `name` | yes | — | Project name, used in branch names and reports |
| `language` | no | auto-detect | Primary language (python, javascript, rust, go, java, ruby) |
| `test_command` | yes | — | Full test suite command. Must exit 0 on success. |
| `lint_command` | no | none | Linter with auto-fix. Run during Polish. |
| `format_command` | no | none | Formatter. Run during Polish before lint. |
| `build_command` | no | none | Build/install command. Run before tests. |
| `smoke_command` | no | none | Fast smoke test. Run during Execute for early failure detection. |

### `modes`

Controls which mode the loop runs in and mode-specific overrides.

```yaml
modes:
  default: strategy                   # default mode when --mode not specified
  overrides:
    backtest:
      test_command: "pytest tests/ -v -m backtest"
    user_only:
      paths:
        source: []                    # no source modifications in user-only mode
```

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `default` | no | `strategy` | Default mode: strategy, backtest, exploration, user_only, dev_only |
| `overrides` | no | `{}` | Per-mode overrides for any other config section |

### `spec_surface`

Defines the project's specification surface for coverage tracking.

```yaml
spec_surface:
  dimensions:
    - name: commands
      values: [init, build, run, test, deploy]
      weight: 2                       # optional, higher = prioritized more
    - name: flags
      values: [--verbose, --quiet, --dry-run, --force]
    - name: input_types
      values: [valid, missing, corrupt, empty]
  blocked:
    - {commands: deploy, flags: --dry-run}
    - {commands: test, input_types: corrupt}
```

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `dimensions` | no | auto-inferred | List of dimensions, each with name, values, and optional weight |
| `dimensions[].name` | yes | — | Dimension name (used in coverage map keys) |
| `dimensions[].values` | yes | — | List of possible values for this dimension |
| `dimensions[].weight` | no | `1` | Priority weight. Higher = ideation favors uncovered values here. |
| `blocked` | no | `[]` | Combinations that should not be exercised (not supported, known invalid) |

If `spec_surface` is omitted, KitchenLoop will attempt to infer dimensions from
the project structure (e.g., CLI subcommands from `--help`, API endpoints from
route definitions).

### `stop_conditions`

Hard safety boundaries. The loop halts when any condition is triggered.

```yaml
stop_conditions:
  max_iterations: 100                 # total iteration cap
  min_pass_rate: 0.95                 # test pass rate floor (0.0 to 1.0)
  max_consecutive_failures: 3         # halt after N failed iterations in a row
  min_test_count_delta: 0             # halt if test count decreases
  max_duration_hours: 24              # halt after N hours of wall time
  coverage_target: 0.80               # halt when spec surface coverage reaches this
```

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `max_iterations` | no | `100` | Maximum total iterations |
| `min_pass_rate` | no | `0.95` | Minimum test pass rate. Halt if it drops below. |
| `max_consecutive_failures` | no | `3` | Halt after N consecutive failed iterations |
| `min_test_count_delta` | no | `0` | Halt if test count drops by more than this |
| `max_duration_hours` | no | `24` | Maximum wall-clock hours |
| `coverage_target` | no | `1.0` | Halt when coverage reaches this (0.0 to 1.0) |

### `ticketing`

Where tickets (work items) are tracked.

```yaml
ticketing:
  provider: github                    # github, gitlab, or local
  github:
    repo: owner/repo                  # optional, auto-detected from git remote
    labels: [kitchenloop]             # labels to apply to created issues
    project: "My Board"               # optional, GitHub project board name
  local:
    file: .kitchenloop/backlog.json   # local JSON file (default for local provider)
```

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `provider` | no | `local` | Ticket provider: `github`, `gitlab`, or `local` |
| `github.repo` | no | auto-detect | GitHub repo in `owner/repo` format |
| `github.labels` | no | `[kitchenloop]` | Labels applied to created issues |
| `github.project` | no | none | GitHub project board name |
| `local.file` | no | `.kitchenloop/backlog.json` | Path to local backlog file |

### `review`

External reviewer configuration for the Triage phase.

```yaml
review:
  enabled: true                       # enable external review
  provider: claude                    # claude, codex, gemini, coderabbit, human
  timeout_seconds: 30                 # timeout before auto-PROCEED
  max_rejections: 2                   # max rejections before tie-breaker fallback
  post_merge_review:
    enabled: true                     # also review merged PRs (e.g., CodeRabbit)
    provider: coderabbit
```

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `enabled` | no | `false` | Enable external review in Triage phase |
| `provider` | no | `claude` | Review provider |
| `timeout_seconds` | no | `30` | Timeout before auto-PROCEED |
| `max_rejections` | no | `2` | Max rejections per iteration before tie-breaker |
| `post_merge_review.enabled` | no | `false` | Enable post-merge review |
| `post_merge_review.provider` | no | same as `provider` | Post-merge review provider |

### `paths`

Defines the repo contract: what the loop can read, modify, and must never touch.

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
    - .env.*
    - credentials/
    - secrets/
    - migrations/
    - vendor/
    - node_modules/
    - "*.lock"
```

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `source` | no | auto-detect | Directories the loop may modify for features |
| `tests` | no | auto-detect | Directories the loop may modify for tests |
| `docs` | no | `[]` | Directories the loop may modify for documentation |
| `exclude` | no | common patterns | Paths the loop must never read or modify |

If `source` and `tests` are omitted, KitchenLoop auto-detects based on language
conventions (e.g., `src/` + `tests/` for Python, `src/` + `__tests__/` for JS).

### `git`

Git workflow configuration.

```yaml
git:
  base_branch: main                   # branch to create worktrees from
  branch_prefix: kitchenloop/         # prefix for iteration branches
  merge_strategy: squash              # squash or merge
  delete_branch_after_merge: true     # clean up merged branches
  commit_message_prefix: "kl:"       # prefix for commit messages
```

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `base_branch` | no | `main` | Base branch for worktrees and PRs |
| `branch_prefix` | no | `kitchenloop/` | Prefix for iteration branch names |
| `merge_strategy` | no | `squash` | PR merge strategy: `squash` or `merge` |
| `delete_branch_after_merge` | no | `true` | Delete branch after successful merge |
| `commit_message_prefix` | no | `""` | Prefix for all commit messages |

### `quality`

Quality gates beyond the test suite.

```yaml
quality:
  require_lint_pass: true             # lint must pass before PR
  require_format_pass: true           # format check must pass before PR
  max_files_per_iteration: 10         # limit scope of changes
  max_lines_per_iteration: 500        # limit scope of changes
  require_test_addition: false        # every iteration must add at least one test
```

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `require_lint_pass` | no | `true` | Lint must pass for PR to be opened |
| `require_format_pass` | no | `true` | Format check must pass for PR to be opened |
| `max_files_per_iteration` | no | `10` | Max files created/modified per iteration |
| `max_lines_per_iteration` | no | `500` | Max lines changed per iteration |
| `require_test_addition` | no | `false` | Require at least one new test per iteration |

### `logging`

Controls log output and verbosity.

```yaml
logging:
  level: info                         # debug, info, warn, error
  file: .kitchenloop/loop.log         # log file path
  json: false                         # structured JSON logging
```

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `level` | no | `info` | Log level |
| `file` | no | `.kitchenloop/loop.log` | Log file path |
| `json` | no | `false` | Enable structured JSON log output |

---

## Environment Variables

Environment variables override config file values. The naming convention is
`KITCHENLOOP_` followed by the section and field in uppercase, joined by `_`.

| Variable | Overrides | Example |
|----------|-----------|---------|
| `KITCHENLOOP_PROJECT_NAME` | `project.name` | `my-project` |
| `KITCHENLOOP_PROJECT_TEST_COMMAND` | `project.test_command` | `pytest` |
| `KITCHENLOOP_STOP_MAX_ITERATIONS` | `stop_conditions.max_iterations` | `50` |
| `KITCHENLOOP_REVIEW_ENABLED` | `review.enabled` | `true` |
| `KITCHENLOOP_REVIEW_PROVIDER` | `review.provider` | `codex` |
| `KITCHENLOOP_GIT_BASE_BRANCH` | `git.base_branch` | `develop` |
| `KITCHENLOOP_LOG_LEVEL` | `logging.level` | `debug` |

Additionally, these external variables are used:

| Variable | Purpose |
|----------|---------|
| `ANTHROPIC_API_KEY` | Required for Claude Code CLI |
| `GITHUB_TOKEN` | Required for GitHub ticketing provider (usually set by `gh auth`) |
| `OPENAI_API_KEY` | Required if using Codex as reviewer |
| `GOOGLE_API_KEY` | Required if using Gemini as reviewer |

---

## Config Validation

KitchenLoop validates the config file at startup. It will fail fast with a
clear error if:

- `project.name` is missing
- `project.test_command` is missing
- `spec_surface.dimensions` contains duplicates
- `spec_surface.blocked` references dimensions or values that do not exist
- `stop_conditions.min_pass_rate` is outside 0.0-1.0
- `paths.exclude` patterns match `paths.source` or `paths.tests`
- `review.provider` is not a recognized provider name

Warnings (non-fatal) are issued for:
- Missing `lint_command` (Polish phase will skip linting)
- Missing `format_command` (Polish phase will skip formatting)
- No `spec_surface` defined (auto-inference will be attempted)
