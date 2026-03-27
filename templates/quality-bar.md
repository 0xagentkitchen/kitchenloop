# Quality Bar — {{PROJECT_NAME}}

## Test Level Requirements (Unbeatable Tests)

Tests are classified into 4 levels. **L1/L2 alone are insufficient** — the regression
gate MUST include L3 to catch the "38 passing unit tests, broken service" failure mode.

| Level | Required? | What It Proves |
|-------|-----------|----------------|
| L1 Unit | Yes | Logic correctness (pure functions, isolated modules) |
| L2 API/Adapter | Yes | Contracts hold (method signatures, API schemas) |
| **L3 Integration** | **Yes — critical** | **Real app starts, real requests succeed, real state changes** |
| L4 E2E Scenario | Via UAT gate | Complete user journeys work end-to-end |

**New features touching integration points MUST include an L3 test** (or extend an
existing one). An L3 test starts the real application, sends a real request, and verifies
a real state delta — no mocks at the system boundary.

See `.kitchenloop/unbeatable-tests.md` for project-specific L3/L4 guidance.

## Code Quality

- All existing tests pass (no regressions)
- New code has test coverage for happy path + primary error case
- Linting passes with zero errors
- No TODO/FIXME/HACK comments in shipped code (use tickets instead)
- No secrets, API keys, or credentials committed

## PR Standards

- PR title is descriptive (under 70 characters)
- PR body includes summary and test plan
- Changes are focused (one concern per PR)
- No unrelated formatting changes mixed with functional changes

## Safety

- No destructive operations without confirmation
- Error handling at system boundaries (user input, external APIs)
- No silent failures — errors are logged or surfaced

## Documentation

- Public API changes are reflected in docs
- Complex logic has inline comments explaining "why" (not "what")
