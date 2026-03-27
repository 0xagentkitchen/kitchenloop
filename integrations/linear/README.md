# Integration: Linear

Linear replaces GitHub Issues as the ticketing backend. It provides richer project management — priorities with levels, blocking/blocked-by relationships, team workflows, custom labels, and cycle tracking.

## Why Linear?

GitHub Issues works fine for small projects, but the label-based state machine (`kitchenloop:todo`, `kitchenloop:in-progress`, etc.) has limitations:

- **No real priorities** — GitHub labels are flat strings; Linear has 4 priority levels (Urgent, High, Normal, Low)
- **No blocking relationships** — the loop can't express "ticket A blocks ticket B"
- **No label filtering for ticket types** — you can't easily flag tickets as "Discussion" (human-only) or "Moonshot" (too ambitious for auto-execution)
- **No project/cycle tracking** — everything is a flat list
- **Concurrent label edits conflict** — two loop iterations editing labels on the same issue can race

Linear solves all of these natively.

## Prerequisites

1. A [Linear](https://linear.app) workspace
2. The Linear MCP server configured in Claude Code

### Setting Up Linear MCP

Add to your Claude Code MCP config (`~/.claude/mcp.json` or project-level):

```json
{
  "mcpServers": {
    "linear": {
      "type": "url",
      "url": "https://mcp.linear.app/sse",
      "headers": {
        "x-api-key": "lin_api_YOUR_API_KEY"
      }
    }
  }
}
```

Get your API key from: Linear Settings > API > Personal API Keys.

Verify it works:

```bash
claude -p "List my Linear teams using the Linear MCP server"
```

## Configuration

Update `kitchenloop.yaml`:

```yaml
ticketing:
  provider: "linear"
  linear:
    team: "MyTeam"              # Your Linear team name
    project: "My Project"        # Linear project to file tickets under
    labels:
      # Type labels (used by triage phase)
      bug: "Bug"
      feature: "Feature"
      improvement: "Improvement"
      quick_win: "Quick Win"
      exploration: "Exploration"
      # Exclusion labels (tickets with these labels are skipped by execute)
      discussion: "Discussion"   # Requires human debate, not auto-executable
      moonshot: "Moonshot"       # Too ambitious for autonomous execution
    priorities:
      critical: 1                # Urgent — today
      high: 2                    # High — this week
      medium: 3                  # Normal — this sprint
      low: 4                     # Low — backlog
```

## How It Works

When `provider: linear`, the loop phases use Claude Code's Linear MCP tools directly instead of `gh issue` commands:

| Phase | GitHub Issues | Linear |
|-------|--------------|--------|
| **Triage** | `gh issue create --label "bug,kitchenloop:todo"` | `mcp__linear__create_issue` with team, project, labels, priority, blocking relationships |
| **Execute** | `gh issue list --label "kitchenloop:todo"` | `mcp__linear__search_issues` filtering by state, excluding Discussion/Moonshot labels |
| **Polish** | `gh issue edit --add-label` | `mcp__linear__update_issue` to transition state |
| **Backlog** | `gh issue list --label "kitchenloop:backlog"` | `mcp__linear__search_issues` with priority sorting |

### Label-Based Filtering

The key feature Linear enables is **exclusion labels**. Two labels prevent tickets from being auto-executed:

**Discussion** — Tickets that need human judgment or multi-AI debate before implementation. The execute phase skips these entirely. They're picked up by the Discussion Manager (see [discussion-manager integration](../discussion-manager/)) or by humans.

**Moonshot** — Ambitious tickets that are too complex or risky for autonomous execution. They stay in the backlog as inspiration for future work. The backlog grooming phase never promotes Moonshots to todo unless the queue is otherwise empty.

### Blocking Relationships

Linear natively supports `blocks` and `blockedBy` relationships. The triage phase sets these when findings are related:

```
VIB-100: "Add retry logic to API client"
  blocks: VIB-101
VIB-101: "Add timeout configuration"
  blockedBy: VIB-100
```

The execute phase checks `blockedBy` before picking up a ticket — if any blocker is still open, the ticket is skipped.

## Prompt Modifications

When using Linear, add these lines to your prompt files:

### `prompts/execute.md` — Add to Step 2 (Pick Top Tickets):

```markdown
Query "todo" tickets from Linear, sorted by priority. **Filter out**:
- Tickets labeled "Discussion" (require human debate)
- Tickets labeled "Moonshot" (too ambitious for auto-execution)
- Tickets with unresolved `blockedBy` dependencies
```

### `prompts/backlog.md` — Add to Step 4 rules:

```markdown
- Do NOT promote Discussion tickets — they require human debate
- Do NOT promote Moonshot tickets unless the queue is otherwise empty
```

### `prompts/triage.md` — Add to Step 4 (Create Tickets):

```markdown
When creating tickets, set `blocks`/`blockedBy` dependencies between related findings.
Use the "Discussion" label for findings that need architectural debate before implementation.
Use the "Moonshot" label for ambitious ideas that require significant new infrastructure.
```

## Migration from GitHub Issues

If you started with GitHub Issues and want to switch:

1. Update `kitchenloop.yaml` with the Linear config above
2. Create the labels in Linear (Bug, Feature, Improvement, Quick Win, Exploration, Discussion, Moonshot)
3. Existing GitHub Issues stay as-is — the loop will create new tickets in Linear going forward
4. Optionally migrate open issues manually (Linear has a GitHub import feature)

## Verified With

This integration has been validated in production across 113+ iterations, producing 220+ tickets with proper priority levels, blocking relationships, and label-based filtering. The Discussion and Moonshot labels prevented ~15% of tickets from being auto-executed — correctly, as those tickets genuinely required human judgment.
