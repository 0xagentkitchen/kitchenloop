# Unbeatable Tests — {{PROJECT_NAME}}

> An "unbeatable" test verifies **ground truth that the code author cannot fake**.
> It catches the failure mode where 38 unit tests pass but the service is completely broken.

## The 4-Level Testing Pyramid

| Level | What | Trust | Gate Role |
|-------|------|-------|-----------|
| **L1 Unit** | Isolated logic, pure functions | Low — proves logic, not integration | Fast CI feedback |
| **L2 API/Adapter** | Methods with real dependencies | Medium — proves contracts | Pre-merge gate |
| **L3 Integration** | Full execution pipeline | High — proves real-world behavior | **Regression oracle** |
| **L4 E2E Scenario** | Complete user journeys | Highest — proves the product works | **UAT gate** |

**L1 and L2 are necessary but not sufficient.** A test that only checks layers 1-2 is
dangerously incomplete — it can silently succeed while doing the wrong thing. L3 and L4
are the "unbeatable" tests because they verify against ground truth.

## What Makes a Test "Unbeatable"

The 4-layer verification pattern for each test:

1. **Compilation** — does it build/compile?
2. **Execution** — does it run without errors?
3. **Output Parsing** — does the output contain what we expect?
4. **State Deltas** — did the actual state match expectations?

A test that only checks layers 1-2 can silently succeed while doing the wrong thing.
**Layer 4 (state deltas) is what makes it unbeatable.**

---

## What "Unbeatable" Means for {{PROJECT_NAME}}

{{UNBEATABLE_DEFINITION}}

### Current Test Level Audit

{{TEST_AUDIT}}

### What L3 Looks Like Here

{{L3_DESCRIPTION}}

**Smoke test command**: `{{SMOKE_COMMAND}}`

### What L4 Looks Like Here

{{L4_DESCRIPTION}}

---

## Bootstrap Priority

If L3 tests do not yet exist, **the first loop iteration MUST create one** before doing
any feature work. A loop without an L3 smoke test is running blind — the regression gate
is disconnected from whether the product actually works.

### Minimum Viable L3 Test Checklist

- [ ] Starts the real application (not a mock)
- [ ] Sends a real request (HTTP, CLI command, API call)
- [ ] Asserts on the response (status code, output content)
- [ ] Verifies a state delta (database row, file created, side effect)
- [ ] Cleans up after itself (teardown, temp files)

### L3 Bootstrap Patterns by Project Type

**Web App / API**:
```bash
# Start server, hit health endpoint, verify response
npm start &
sleep 3
curl -sf http://localhost:3000/health | grep -q '"ok"'
# Hit a real route, verify it returns data
curl -sf http://localhost:3000/api/items | jq '.length > 0'
kill %1
```

**CLI Tool**:
```bash
# Run the actual CLI with real input, verify output
echo '{"input": "test"}' | my-cli process --format json | jq '.status == "ok"'
# Verify side effects (file created, exit code)
my-cli generate --output /tmp/test-output
test -f /tmp/test-output/result.json
```

**Library / SDK**:
```bash
# Run an integration script that exercises the public API end-to-end
python -c "
from mylib import Client
c = Client()
result = c.process('test-input')
assert result.status == 'ok', f'Expected ok, got {result.status}'
assert len(result.data) > 0, 'No data returned'
"
```

**Web App (Browser)**:
```bash
# Start app, use headless browser to verify rendering
npm start &
sleep 3
npx playwright test tests/smoke.spec.ts
kill %1
```
