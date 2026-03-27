# Skill: Discussion Moderator

## Description
Orchestrate a structured multi-AI discussion. Gemini and Codex debate via CLI,
Claude debates via an isolated subagent, and **you** are the impartial moderator.

## Triggers
- "discuss", "start a discussion about", "debate", "have the AIs argue about"
- "discussion moderator"

## Hard requirement: all 3 debaters must be available

If **any** debater CLI is unavailable (auth expired, not installed, crashing),
**cancel the discussion immediately** and report the failure to the user.
Do NOT proceed with 2 debaters. Do NOT silently skip a model.

```
Abort: Gemini auth expired. Discussion cancelled.
Please run `gemini` in an interactive terminal to re-authenticate, then retry.
```

The script enforces this by default (`--require-all-models` is the default).
`--allow-missing-models` exists only for debugging, never for production runs.

## Architecture

```
You (Moderator) -- impartial, never participates in the debate
  |
  |-- discuss.py --run-turn gemini    (Gemini CLI)
  |-- discuss.py --run-turn codex     (Codex CLI)
  |-- discuss.py --get-prompt claude  --> Task subagent (Claude DEBATER, isolated)
  |       echo "$response" | discuss.py --add-response claude
  |-- discuss.py --status             (mechanical convergence check)
  |
  After debate:
  |-- discuss.py --save-report        (write structured summary into convo.json)
```

**Isolation model**: The Claude debater subagent sees ONLY the debate prompt.
It has no access to your moderator reasoning. You see only its output.
The subagent boundary is the information firewall.

## Instructions

### Phase 1: Pre-flight check + create the conversation

First verify all 3 CLIs respond before starting:

```bash
gemini -p "ping" 2>&1 | head -1   # must NOT contain "Error authenticating"
codex exec "ping" 2>&1 | tail -1  # must produce output
# Claude debater runs via subagent -- no CLI check needed
```

If Gemini fails: tell the user to run `gemini` in an interactive terminal to
re-authenticate, then retry. **Do not proceed.**

If all CLIs are healthy:

```bash
CONVO=$(python scripts/ai-discussion/discuss.py "TOPIC" \
  --models gemini codex claude \
  --max-rounds 5 --max-words 400 \
  --create-only)
```
This prints the JSON file path to stdout. Capture it in `$CONVO`.

If the user specifies context, add `--context "..."`.
If the user specifies particular models or rounds, adjust accordingly.

#### Discussion modes

Choose the appropriate mode for the discussion type:

- **`--mode audit`** (default): For code reviews and independent parallel evaluation.
  No kill gate. Standard debate flow.
- **`--mode design`**: For architecture decisions, feature discussions, and PRDs.
  Activates the **kill gate**: each debater must argue "why this should NOT be built"
  in round 1 before proceeding with analysis. If the NO argument is not adequately
  rebutted, the discussion can conclude with a rejection.

#### Moderator mode

- **`--moderator-mode neutral`** (default): Moderator reports consensus, flags errors,
  and notes blind spots but never recommends.
- **`--moderator-mode arbitrating`**: Moderator may recommend a specific resolution
  when debaters are deadlocked. Recommendations are clearly stamped.

Example for an architecture discussion:
```bash
CONVO=$(python scripts/ai-discussion/discuss.py "TOPIC" \
  --models gemini codex claude \
  --mode design --moderator-mode neutral \
  --max-rounds 5 --max-words 400 \
  --create-only)
```

#### Codebase access for technical discussions

For discussions about the codebase itself (architecture, features, implementation decisions),
give debaters codebase access **before** starting the debate:

**Option A — Targeted file injection (recommended for all debaters):**
Pass specific files with `--codebase-files`. Their contents are injected into every
debater prompt. Gemini gets a guided file list (it has autonomous file tools);
Codex and Claude get full file content embedded directly.

```bash
# Inject relevant files into every debater's prompt:
CONVO=$(python scripts/ai-discussion/discuss.py "TOPIC" \
  --models gemini codex claude \
  --codebase-files whitepaper.md \
                   scripts/kitchenloop/kitchenloop.sh \
  --context "..." \
  --create-only)
```

**Option B — Use prep-codebase-context.sh for a topic-aware summary:**
The helper script reads the most relevant files for a given topic and
outputs a compact context block suitable for `--context`:

```bash
CTX=$(scripts/ai-discussion/prep-codebase-context.sh architecture)
CONVO=$(python scripts/ai-discussion/discuss.py "TOPIC" \
  --context "$CTX" \
  --create-only)
```
Valid topic keywords: `architecture`, `loop`, `prompts`, `discussion`.
Customize the script to add your own topic-to-file mappings.

**Gemini already has autonomous file access** — it runs with `--include-directories`
pointing to the repo root and `--approval-mode plan` (read-only). Gemini can
search and read any file in the repo but cannot write or execute anything.
The codebase context in its prompt becomes a guided index for deeper searches.

**Codex gets file content injected** — since Codex has no autonomous file tools
in this mode, the `--codebase-files` content is embedded directly in its prompt.

**Claude subagent** — the codebase section from `--get-prompt` is already included
in the prompt it receives.

### Phase 2: Run the debate loop

For each round, run all three debaters in order, then check status.

**Rate-limit handling**: `--run-turn` exits with code `3` if rate-limited (turn NOT saved).
If exit code is 3, wait 30s and retry the same command once before giving up.

```bash
# 1. Gemini (via CLI)
python scripts/ai-discussion/discuss.py --resume "$CONVO" --run-turn gemini
# exit 3 = rate limited — wait 30s and retry

# 2. Codex (via CLI)
python scripts/ai-discussion/discuss.py --resume "$CONVO" --run-turn codex

# 3. Claude (via isolated subagent)
PROMPT=$(python scripts/ai-discussion/discuss.py --resume "$CONVO" --get-prompt claude)
```

Then launch a **Task subagent** for Claude's debater turn:

```
Task(
  subagent_type="general-purpose",
  name="claude-debater",
  prompt="""You are Claude, a debater in a multi-AI discussion.
You are a DEBATER only. You must argue your position substantively.
Do NOT moderate, summarize, or write a report. Just debate.

Read the prompt below and respond EXACTLY as instructed, including
the required STANCE/AGREEMENTS/DISAGREEMENTS footer.

<debate-prompt>
{the prompt from --get-prompt}
</debate-prompt>

Return ONLY your debate response. Nothing else."""
)
```

The subagent returns Claude's debate response. Inject it:

```bash
echo "$CLAUDE_RESPONSE" | python scripts/ai-discussion/discuss.py \
  --resume "$CONVO" --add-response claude
```

Then check convergence:

```bash
python scripts/ai-discussion/discuss.py --resume "$CONVO" --status
```

This prints JSON with `converged`, `pending`, `round`, `status`, and `quality_metrics` fields.
The `quality_metrics` object includes turn validity counts, position changes, and issue register stats.

**Loop control**:
- If `converged: true` AND `round >= 3` (min 2 complete rounds): stop the debate
- If `round > max_rounds`: stop the debate
- If `status` is `"converged"` or `"max_rounds_reached"`: stop
- Otherwise: run the next round

### Phase 2.5: Set proposal artifact (optional)

If the debate produced a concrete design document or PRD, set it as the proposal
artifact before ratification. Debaters will ratify this specific document rather
than the general mood from the last round:

```bash
cat design-doc.md | python scripts/ai-discussion/discuss.py --resume "$CONVO" --set-proposal
```

### Phase 2.6: Ratification round

After the debate loop ends (whether converged or max_rounds_reached), always run
a ratification pass. This turns "we mostly agreed" into an **explicit sign-off**.

```bash
# Gemini and Codex: ratify via CLI
python scripts/ai-discussion/discuss.py --resume "$CONVO" --ratify gemini
python scripts/ai-discussion/discuss.py --resume "$CONVO" --ratify codex
# exit 3 = rate limited — wait 30s and retry

# Claude: ratify via isolated subagent
RATIFY_PROMPT=$(python scripts/ai-discussion/discuss.py --resume "$CONVO" --get-ratify-prompt claude)
```

Launch a Task subagent for Claude's ratification:

```
Task(
  subagent_type="general-purpose",
  name="claude-ratifier",
  prompt="""You are Claude, ratifying a design that emerged from a multi-AI debate.
Read the ratification prompt and respond with:
1. Whether you RATIFY the design (yes / no / conditional)
2. Any remaining objections
3. Your concrete answers to any open questions

<ratify-prompt>
{the prompt from --get-ratify-prompt}
</ratify-prompt>

End your response with the required RATIFIES/OBJECTIONS/RESOLUTIONS footer.
Return ONLY your ratification response. Nothing else."""
)
```

Inject Claude's ratification:

```bash
echo "$CLAUDE_RATIFICATION" | python scripts/ai-discussion/discuss.py \
  --resume "$CONVO" --add-ratification claude
```

The `--status` output will now show `ratified_by` and `ratify_pending` fields.
A fully ratified discussion has an empty `ratify_pending` list.

### Phase 3: Write the moderator synthesis

After the ratification round, read the full conversation JSON file.

You are now the **neutral moderator**. Your job is to faithfully represent
what was said. You did NOT participate in the debate.

Produce the synthesis as a structured JSON object (see schema below), PLUS
a full markdown report for presenting to the user.

**Moderator rules (strict)**:
1. Do NOT state which debater was "right" or "better"
2. Do NOT add your own recommendation on the topic
3. DO flag factual errors (cite the error neutrally)
4. DO note if all debaters missed something ("neither addressed X")
5. Keep it concise
6. **For every open question**: provide a recommended resolution or escalation path.
   Do NOT leave open questions as a list with no answer — state what should happen next.

### Phase 4: Save structured report into convo.json

Write the report back into the conversation JSON file via `--save-report`.
This makes the convo.json a **complete, self-contained handoff artifact**.

The report JSON **must** have these fields:

```json
{
  "conclusion": "agreed" | "agreed_to_disagree" | "partial",
  "problem_statement": "One sentence: what was being decided or designed.",
  "key_takeaways": [
    "Concrete actionable point 1",
    "Concrete actionable point 2"
  ],
  "friction_points": [
    "Point debaters still disagreed on at the end",
    "..."
  ],
  "open_questions": [
    "Things no debater addressed that future work should answer",
    "..."
  ],
  "synthesis": "Full markdown moderator synthesis (the report body). Include Consensus, Disagreements, Stance Evolution table, and Moderator Notes sections.",
  "prd_file": null
}
```

Save it:

```bash
cat <<'EOF' | python scripts/ai-discussion/discuss.py --resume "$CONVO" --save-report
{
  "conclusion": "agreed",
  "problem_statement": "...",
  "key_takeaways": ["..."],
  "friction_points": ["..."],
  "open_questions": ["..."],
  "synthesis": "..."
}
EOF
```

### Phase 5: Create a PRD or outcome document (if warranted)

**When to create a separate outcome document:**
- The discussion produced a PRD, implementation plan, or architectural decision
- The synthesis is large enough that it would overwhelm a ticket description
- The outcome will be referenced by future work / other agents

**When NOT to create one:**
- The conclusion is "agreed_to_disagree" with no actionable output
- The synthesis fits naturally as a brief summary

If a PRD or outcome document is warranted, save it to:

```
docs/internal/discussions/<topic-slug>-<YYYYMMDD>.md
```

Then update the `prd_file` field in the saved report:

```bash
cat <<'EOF' | python scripts/ai-discussion/discuss.py --resume "$CONVO" --save-report
{
  ...all fields...,
  "prd_file": "docs/internal/discussions/topic-slug-20260226.md"
}
EOF
```

### Phase 6: Report to user

Present the markdown synthesis report to the user. Also mention:
- The conversation file path (for raw inspection)
- They can resume with `--resume` if they want more rounds
- Whether a PRD was created and where
- Suggest follow-up questions if interesting threads emerged

## The convo.json as a handoff artifact

The conversation JSON is a **complete handoff artifact** after Phase 4. Any agent
(or human) can read it and immediately understand:

```json
{
  "topic": "...",
  "context": "...",          // problem statement / context
  "turns": [...],            // full debate transcript
  "final_report": {
    "conclusion": "agreed",
    "problem_statement": "...",
    "key_takeaways": ["..."],
    "friction_points": ["..."],
    "open_questions": ["..."],
    "synthesis": "...(full markdown)...",
    "prd_file": "docs/internal/discussions/..."  // or null
  }
}
```

No other context is needed to pick up where the discussion left off.

## Resume / extend

If the user says "continue the debate" or "add more rounds":
1. Find the latest convo file: `ls -t scripts/ai-discussion/conversations/convo-*.json | head -1`
2. Run more rounds using the same Phase 2 loop
3. Re-read JSON and update your synthesis
4. Re-run Phases 4-6 to overwrite the saved report

## Fallback: 2-debater mode

If the user only wants Gemini + Codex (no Claude debater):
```bash
python scripts/ai-discussion/discuss.py "TOPIC" --models gemini codex
```
This runs the full-auto debate. Then read the JSON and write synthesis as above.

## Fallback: self-synthesize (no moderator)

If the user explicitly wants no external moderator:
```bash
python scripts/ai-discussion/discuss.py "TOPIC" --self-synthesize
```
One of the debaters writes the report. Less impartial, but simpler.
