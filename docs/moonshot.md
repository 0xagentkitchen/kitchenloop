# KitchenLoop Moonshots

Future integration ideas tracked here. Not on the roadmap — just ideas worth remembering.

---

## OpenSpecs Integration

Auto-generate the spec surface from OpenAPI/AsyncAPI docs.
Instead of hand-authoring `spec.dimensions` in kitchenloop.yaml, parse the API spec
and generate feature × endpoint × scenario combinations automatically.

**Why it matters**: keeps the spec surface in sync with the actual API contract.

---

## Linear Integration

`tickets.sh` provider=linear — the config stub already exists in kitchenloop.example.yaml.
Linear's GraphQL API supports issue creation, label management, and state transitions.

**Current state**: `ticketing.provider` accepts `github` and `none`. Linear is scaffolded
but unimplemented. The `lib/tickets.sh` adapter pattern is already in place.

---

## Image Creation / Fetching as Ideation Input

Feed AI-generated wireframes or screenshot mockups into the ideation phase.
Give the ideation agent a visual representation of what the UI *should* look like,
then let it discover gaps between the mockup and reality.

---

## Multi-Repo Loop

Coordinate improvements across a monorepo with a shared spec surface.
One kitchenloop.yaml at the monorepo root, each package gets its own worktree,
but the coverage matrix and backlog are shared.

---

## Browser Regression Baselines

Visual diff snapshots between iterations for UI regression detection.
After each UI iteration, save a "golden" screenshot set. Compare against it in the
next iteration to detect visual regressions (layout shifts, missing elements).

Tools: Percy, playwright visual testing, or a simple pixel-diff script.

---

## Streaming Metrics Dashboard

Live loop health visible in the browser while the loop runs.
The loop writes metrics.json after each phase; a local dev server streams these
to a browser dashboard showing pass rate, coverage %, iteration timeline, and
current phase.

---

## LLM Cost Tracking

Token budget enforcement per phase, cost reports per iteration.
Track input/output tokens per Claude invocation, aggregate by phase and iteration,
surface in the loop-state.md and metrics.json. Alert when a phase exceeds its budget.

---

## Periodic UI/UX Polish Pass

The loop should occasionally look at the target app's visual design with fresh eyes
and propose small, incremental improvements — better spacing, typography, color,
hover states, micro-interactions. Not a full redesign, just one or two things that
make the app feel more polished each time.

**Key constraints:**
- Small scope: one visual improvement per pass, not a full overhaul
- Conservative: don't break existing layouts or introduce jarring changes
- Taste-aware: follow modern design trends (2025+) but stay consistent with the app's existing aesthetic
- Not too frequent: maybe every 5-10 iterations, or triggered by a specific config flag
- CSS only: no design frameworks or build tools unless the project already uses them

**Why it matters**: UI quality is table stakes in 2026. A loop that only fixes bugs and adds
features but leaves the app looking like a prototype misses the mark. Small visual polish
compounds — after 20 iterations the app should *feel* better, not just *work* better.

**Open questions**: How to scope this so the loop doesn't go wild? Maybe a `ui_polish.frequency`
config key, or a dedicated `--mode polish-ui` that only does visual improvements.

---

## Spec Surface from Test Files

Auto-generate `spec.dimensions` by parsing existing test files.
Grep for test function names, extract feature/scenario patterns, propose a spec
surface that matches what the codebase already tests.
