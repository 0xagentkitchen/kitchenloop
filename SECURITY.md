# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in KitchenLoop, please report it responsibly.

**Email:** 0xAgentKitchen@gmail.com

**Do NOT open a public GitHub issue for security vulnerabilities.**

Include as much detail as possible: steps to reproduce, affected components, and potential impact. We will acknowledge your report within **48 hours** and work with you to understand and address the issue.

## Security Model

KitchenLoop runs AI agents that autonomously modify code. The framework enforces several layers of defense to ensure these modifications are safe and auditable.

### 1. Isolated Worktrees

All changes are made in disposable git worktrees, never in the working tree. This prevents autonomous agents from interfering with the developer's local state or with each other.

### 2. Oracle Test Suite

The project's test suite is the source of truth. No change merges without passing the full test suite. Tests are written by humans and verified independently of the agents that produce code changes.

### 3. UAT Gate

After implementation, a fresh agent with zero prior context performs adversarial end-to-end verification. This agent has no knowledge of the implementation approach and evaluates the change purely against expected behavior.

### 4. Auto-Revert

Changes that fail any gate (tests, UAT, or triage) are discarded automatically. There is no manual override path in the default loop configuration.

### 5. Audit Trail

Every iteration produces a pull request and a structured report. All agent reasoning, test results, and triage decisions are preserved for human review.

## Scope

The following categories are in scope for security reports:

- **Worktree isolation bypass** -- an agent or script escaping its worktree to modify the working tree or other worktrees.
- **Test suite oracle bypass** -- a path that allows code to merge without passing the required test gates.
- **Unauthorized code execution outside worktree** -- commands running in contexts or directories they should not have access to.
- **Data exfiltration via prompts or skills** -- prompt injection or skill definitions that leak sensitive data from the host environment.
- **Privilege escalation in init script** -- the interactive setup script gaining or granting permissions beyond what is necessary.

## Out of Scope

- Vulnerabilities in third-party dependencies (report these to the respective maintainers).
- Issues that require physical access to the host machine.
- Denial of service against the local loop process.

## Disclosure

We follow coordinated disclosure. Once a fix is released, we will credit reporters (unless anonymity is requested) and publish an advisory describing the issue and remediation.
