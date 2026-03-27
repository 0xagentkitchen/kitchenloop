# Customization Guide

KitchenLoop is designed to be extended. This guide covers how to write
domain-specific skills, define your spec surface, build your regression oracle,
customize the quality bar, and add new ticketing providers.

---

## Writing Domain-Specific Skills

Skills are markdown files that give Claude Code domain knowledge about your
project. Place them in `.claude/skills/` in your project root.

### Skill File Structure

```
.claude/skills/
  my-domain/
    SKILL.md          # skill definition (required)
    examples/         # optional example files
```

### Skill Definition Format

```markdown
# Skill: Database Migration Testing

## When to use
Use this skill when the iteration involves database schema changes or
migration testing.

## Context
This project uses Alembic for migrations. Migration files are in
`migrations/versions/`. Every migration must be reversible.

## Rules
1. Always test both upgrade and downgrade paths
2. Never modify existing migration files, only create new ones
3. Test with a fresh database AND with existing data
4. Check that indexes are created for foreign keys

## Test patterns
- `pytest tests/migrations/ -v` runs migration-specific tests
- Each migration test creates a temp database, applies migrations, verifies schema

## Common pitfalls
- Forgetting to add `batch_alter_table` for SQLite compatibility
- Missing `downgrade()` implementation
- Not handling NULL values in existing rows during ALTER TABLE
```

### How Skills Are Used

During the Ideate and Execute phases, KitchenLoop loads relevant skills based
on the iteration's scope. If the proposal involves files in `migrations/`, the
migration testing skill above would be loaded automatically.

Skills are additive. They provide context and constraints but do not override
the core loop behavior. The verification contract (test suite passes, pass rate
floor, etc.) always applies.

### Tips for Effective Skills

- Keep skills focused: one domain per skill, 50-200 lines
- Include concrete file paths and command examples
- List common pitfalls specific to your project
- Reference your project's conventions, not generic best practices

---

## Defining Your Spec Surface

The spec surface tells KitchenLoop what your project should be able to do. A
well-defined spec surface produces better coverage and more targeted iterations.

### Choosing Dimensions

Good dimensions are orthogonal axes of variation in your project's behavior:

| Project Type | Good Dimensions | Poor Dimensions |
|-------------|-----------------|-----------------|
| CLI tool | commands, flags, input types, output formats | file sizes, OS versions |
| REST API | endpoints, methods, auth roles, payload types | network latency, DB size |
| Library | public functions, input types, edge cases | internal methods, line counts |
| Data pipeline | sources, transforms, sinks, error modes | row counts, timestamps |

A dimension is **good** if changing its value changes the code path exercised.
A dimension is **poor** if it only changes non-functional properties.

### Sizing the Surface

The total surface is the cross-product of all dimensions minus blocked
combinations. Aim for:

- **50-200 total combinations** for a focused loop (50-100 iterations)
- **200-1000 combinations** for a comprehensive loop (100+ iterations)
- **Under 50** means the surface is too small to justify automation
- **Over 1000** means you should split into sub-surfaces or reduce dimensions

### Blocked Combinations

Not all combinations are valid. Use `blocked` to exclude impossible or
unsupported combinations:

```yaml
spec_surface:
  blocked:
    # Single value block
    - {endpoints: /health, methods: DELETE}

    # Multiple values block (any match)
    - {methods: [POST, PUT], endpoints: /health}

    # Multi-dimension block
    - {auth: anonymous, methods: DELETE, endpoints: /users/{id}}
```

### Evolving the Surface

Your spec surface is not static. As the project grows, update
`kitchenloop.yaml` to add new dimensions or values. The coverage map
automatically accounts for new coordinates (they start uncovered).

Remove dimensions that are no longer meaningful. The coverage map retains
historical entries even if their coordinates no longer exist in the active
surface.

---

## Building Your Regression Oracle

The regression oracle is the test command that determines whether a change is
safe to merge. It must meet two requirements:

1. **Exit code**: 0 for all tests passing, non-zero for any failure
2. **Determinism**: running the same tests twice should produce the same result

### Basic Oracle

```yaml
project:
  test_command: "pytest tests/ -v"
```

### Multi-Step Oracle

If your project needs multiple test stages:

```yaml
project:
  test_command: "pytest tests/unit && pytest tests/integration && npm run e2e"
```

The command is run as a single shell invocation. If any step fails (non-zero
exit), the entire oracle fails.

### Oracle with Setup

```yaml
project:
  build_command: "docker compose up -d && sleep 5"
  test_command: "pytest tests/ -v"
```

The `build_command` runs before `test_command`. If `build_command` fails, the
iteration fails at the Execute phase (before PR creation).

### Customizing Stop Conditions

Tune the oracle's sensitivity:

```yaml
stop_conditions:
  # Strict: high-confidence projects
  min_pass_rate: 0.99
  max_consecutive_failures: 2
  min_test_count_delta: 0

  # Relaxed: early-stage projects with known flaky tests
  min_pass_rate: 0.85
  max_consecutive_failures: 5
  min_test_count_delta: -5     # tolerate some test removal
```

### Handling Flaky Tests

If your test suite has known flaky tests, you have two options:

1. **Mark them** (preferred): Use your framework's skip/xfail mechanism so they
   do not affect pass rate
2. **Lower the floor**: Set `min_pass_rate` below 1.0 to tolerate occasional
   failures. Not recommended long-term.

---

## Customizing the Quality Bar

The `quality` section controls what must pass before a PR is opened:

```yaml
quality:
  require_lint_pass: true
  require_format_pass: true
  max_files_per_iteration: 10
  max_lines_per_iteration: 500
  require_test_addition: false
```

### Scope Limits

`max_files_per_iteration` and `max_lines_per_iteration` prevent the loop from
making sweeping changes. Smaller limits produce more focused, reviewable PRs.

For early iterations when the loop is building test infrastructure, you may
want higher limits. Lower them once the project is stable.

### Requiring Test Addition

Set `require_test_addition: true` to ensure every iteration adds at least one
new test. This is useful in dev-only mode where the goal is pure coverage
improvement.

---

## Adding a New Ticketing Provider

KitchenLoop ships with three ticketing providers: `github`, `gitlab`, and
`local`. To add a new one, create a shell script that implements the ticket
interface.

### Ticket Interface

The provider must implement these commands:

```bash
# List open tickets (JSON array)
kitchenloop-tickets list --state open
# Output: [{"id": "1", "title": "...", "state": "backlog", "coordinates": {...}}]

# Create a ticket
kitchenloop-tickets create --title "..." --body "..." --coordinates '{"dim": "val"}'
# Output: {"id": "2"}

# Update ticket state
kitchenloop-tickets update --id 1 --state in_progress
# Output: {"id": "1", "state": "in_progress"}

# Close a ticket
kitchenloop-tickets close --id 1 --reason "merged" --pr "#42"
# Output: {"id": "1", "state": "done"}
```

### Registration

Register your provider in `kitchenloop.yaml`:

```yaml
ticketing:
  provider: custom
  custom:
    list_command: "my-tool tickets list --format json"
    create_command: "my-tool tickets create"
    update_command: "my-tool tickets update"
    close_command: "my-tool tickets close"
```

### Provider Requirements

- All commands must accept and produce JSON
- Ticket IDs must be stable strings
- The `list` command must support `--state` filtering
- The `create` command must accept `--title`, `--body`, and `--coordinates`
- The provider must be idempotent (repeated updates are safe)

---

## Project-Specific Claude Configuration

Beyond skills, you can customize Claude Code's behavior for your project by
placing a `CLAUDE.md` file at your project root. KitchenLoop respects this
file during the Execute phase.

Use `CLAUDE.md` for:
- Import conventions
- Code style rules beyond what a linter catches
- Architecture decisions that affect implementation choices
- File organization guidelines

Do not duplicate information from `kitchenloop.yaml` in `CLAUDE.md`. The config
file is for the loop framework; `CLAUDE.md` is for the AI implementer.
