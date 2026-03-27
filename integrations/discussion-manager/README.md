# Integration: Discussion Manager

The Discussion Manager enables structured multi-AI debates for decisions that require judgment — architecture choices, feature design, "should we build this?" questions, and code reviews that benefit from multiple independent perspectives.

## Why Multi-AI Discussion?

A single model making all decisions has blind spots. Research on sycophancy in multi-agent debate (Yao et al., arXiv:2509.23055v1) shows that heterogeneous model composition — mixing different model families — produces better outcomes than any single model, provided the debate protocol controls for premature convergence.

The Discussion Manager implements this with anti-sycophancy safeguards validated across 24 production discussions.

## Prerequisites

| Tool | Required | Purpose |
|------|----------|---------|
| `claude` | Yes | Moderator + one debater (via isolated subagent) |
| `gemini` | Yes | [Gemini CLI](https://github.com/google-gemini/gemini-cli) — debater with autonomous file access |
| `codex` | Yes | [Codex CLI](https://github.com/openai/codex) — debater |
| Python 3.10+ | Yes | Runs `discuss.py` orchestrator |

### Installing the CLIs

```bash
# Gemini CLI
npm install -g @anthropic-ai/gemini-cli
# Then authenticate: run `gemini` in a terminal and follow prompts

# Codex CLI
npm install -g @openai/codex
# Authenticate via OPENAI_API_KEY env var
```

All 3 debaters must be available. The system aborts if any CLI is unreachable — it does not silently degrade to 2 debaters.

## Usage

### Standalone Discussion (Outside the Loop)

```bash
# Quick 2-model debate (no Claude debater needed)
python scripts/ai-discussion/discuss.py "SQLite vs PostgreSQL for our use case?" \
  --models gemini codex --max-rounds 3

# Full 3-model debate with Claude subagent
python scripts/ai-discussion/discuss.py "Should we rewrite the auth module?" \
  --models gemini codex claude --max-rounds 3 --create-only
# Then orchestrate via Claude Code (see skill instructions)

# With codebase context injected into every turn
python scripts/ai-discussion/discuss.py "Best approach for caching?" \
  --models gemini codex \
  --codebase-files src/cache.py src/config.py \
  --max-rounds 3

# Self-synthesize (one debater writes the report — less impartial)
python scripts/ai-discussion/discuss.py "Monorepo vs polyrepo?" \
  --models gemini codex --self-synthesize
```

### Via Claude Code Skill

In a Claude Code session:

```
discuss whether we should use WebSockets or SSE for real-time updates
```

Claude Code triggers the `discussion-moderator` skill, which:
1. Pre-flight checks all 3 CLIs
2. Creates the conversation
3. Runs the debate loop (Gemini + Codex via CLI, Claude via isolated subagent)
4. Runs a ratification round
5. Writes a neutral moderator synthesis
6. Saves the full transcript to `scripts/ai-discussion/conversations/`

### Inside the Kitchen Loop

The Ideate and Triage phases can invoke discussions for judgment-intensive decisions:

```yaml
# No config needed — the skill is auto-discovered by Claude Code
# Just ensure gemini + codex CLIs are installed and authenticated
```

When the loop encounters a decision it's uncertain about (e.g., "should we add this feature or is it a bad idea?"), it can spawn a discussion. The outcome feeds back into ticket creation.

## Key Files

| File | Purpose |
|------|---------|
| `scripts/ai-discussion/discuss.py` | Orchestrator — manages turns, convergence, ratification |
| `scripts/ai-discussion/prep-codebase-context.sh` | Generates topic-aware codebase context for debates |
| `.claude/skills/discussion-moderator/SKILL.md` | Claude Code skill — 8-phase moderation protocol |

## Architecture

```
Moderator (Claude — your active session)
  |
  |-- discuss.py --run-turn gemini    (Gemini CLI, read-only file access)
  |-- discuss.py --run-turn codex     (Codex CLI)
  |-- discuss.py --get-prompt claude  → isolated subagent (information firewall)
  |-- discuss.py --status             (mechanical convergence check)
  |
  After debate:
  |-- discuss.py --save-report        (structured JSON report)
```

**Information firewall**: The Claude debater runs as an isolated subagent. It sees only the debate prompt — no moderator reasoning, no implementation context, no conversation history from the moderator's session.

## Anti-Sycophancy Safeguards

Based on empirical findings from 24 discussions and the arXiv:2509.23055v1 paper:

1. **Heterogeneous models** — 3 different model families prevent groupthink
2. **Blind opening round** — all debaters submit positions independently before seeing others (roadmap)
3. **Round capping** — default 3-5 rounds; productive disagreement typically ends by round 2-3
4. **Ratification round** — explicit sign-off after debate, not assumed consensus
5. **Structured footers** — every turn ends with STANCE/AGREEMENTS/DISAGREEMENTS for mechanical tracking
6. **Convergence detection** — auto-stops when disagreements reach zero (not by round count alone)

## Output: The Conversation Artifact

Every discussion produces a JSON file in `scripts/ai-discussion/conversations/`:

```json
{
  "topic": "Should we use WebSockets or SSE?",
  "context": "We need real-time updates for the dashboard...",
  "turns": [
    {"round": 1, "model": "gemini", "content": "...", "stance": "...", "disagreements": [...]},
    {"round": 1, "model": "codex", "content": "...", "stance": "...", "disagreements": [...]},
    ...
  ],
  "ratifications": {
    "gemini": {"ratifies": "yes", ...},
    "codex": {"ratifies": "conditional", "objections": ["latency concern"], ...}
  },
  "final_report": {
    "conclusion": "agreed",
    "key_takeaways": ["SSE for our use case because..."],
    "friction_points": ["Codex raised latency concern..."],
    "synthesis": "## Full markdown report..."
  }
}
```

This is a complete handoff artifact — any agent or human can read it and understand the decision, the reasoning, and any unresolved concerns.

## Without the Discussion Manager

The loop works fine without it — Claude makes all judgment calls unilaterally. The Discussion Manager becomes valuable when:
- You're making architectural decisions that are hard to reverse
- You've noticed the loop making poor judgment calls in the Ideate phase
- You want independent review of proposed features before investing implementation time
- You want a traceable record of *why* a decision was made, not just *what* was decided
