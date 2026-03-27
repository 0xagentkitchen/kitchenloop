#!/bin/bash
# tickets.sh — Ticket state machine + provider adapters
#
# Provider-agnostic ticketing API. The orchestrator and PR manager call
# these functions instead of making direct gh/MCP calls.
#
# State machine: backlog → todo → in_progress → in_review → done
#
# Usage:
#   source lib/config.sh && config_load
#   source lib/tickets.sh
#   ticket_create "Fix login bug" "Description here" "bug" "high"
#   ticket_list_by_state "todo"
#   ticket_transition "123" "in_progress"

# Guard against double-sourcing
[[ -n "${_KITCHENLOOP_TICKETS_LOADED:-}" ]] && return 0
_KITCHENLOOP_TICKETS_LOADED=1

# Requires config.sh to be loaded first
if [ -z "${_KITCHENLOOP_CONFIG_LOADED:-}" ]; then
  echo "ERROR: tickets.sh requires config.sh to be loaded first"
  exit 1
fi

# ─── Provider detection ─────────────────────────────────────────────────
_ticket_provider() {
  config_get_default "ticketing.provider" "github"
}

# ─── State label mapping (GitHub) ────────────────────────────────────────
_gh_state_label() {
  local state="$1"
  config_get_default "ticketing.github.state_labels.${state}" "kitchenloop:${state}"
}

_gh_type_label() {
  local type="$1"
  config_get_default "ticketing.github.labels.${type}" "$type"
}

# ─── Local backlog file (none provider) ──────────────────────────────────
_local_backlog_file() {
  local path
  path=$(config_get_default "ticketing.local.file" ".kitchenloop/backlog.json")
  if [[ "$path" != /* ]]; then
    path="${KITCHENLOOP_ROOT}/$path"
  fi
  echo "$path"
}

_ensure_local_backlog() {
  local f
  f=$(_local_backlog_file)
  mkdir -p "$(dirname "$f")"
  if [ ! -f "$f" ]; then
    echo '[]' > "$f"
  fi
}

# ─── ticket_create ──────────────────────────────────────────────────────
# Create a new ticket. Returns the ticket ID.
# Args: title body type priority
ticket_create() {
  local title="$1"
  local body="${2:-}"
  local type="${3:-feature}"
  local priority="${4:-medium}"
  local provider
  provider=$(_ticket_provider)

  case "$provider" in
    github)
      local type_label state_label
      type_label=$(_gh_type_label "$type")
      state_label=$(_gh_state_label "backlog")
      local labels="${type_label},${state_label},priority:${priority}"
      local result
      result=$(gh issue create --title "$title" --body "$body" --label "$labels" 2>&1)
      # Extract issue number from URL
      echo "$result" | grep -o '[0-9]*$' | tail -1
      ;;
    linear)
      # Linear integration is planned but not yet implemented.
      # When available, it will use the Linear API or MCP for full
      # ticket lifecycle management. For now, use 'github' or 'none'.
      echo "ERROR: Linear provider is planned but not yet implemented. Use 'github' or 'none' provider." >&2
      return 1
      ;;
    local|none)
      _ensure_local_backlog
      local f
      f=$(_local_backlog_file)
      local id
      id=$(printf '%s%s%05d' "$(date +%s)" "$$" "$RANDOM")
      local entry
      entry=$(jq -n \
        --arg id "$id" \
        --arg title "$title" \
        --arg body "$body" \
        --arg type "$type" \
        --arg priority "$priority" \
        --arg state "backlog" \
        --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{id: $id, title: $title, body: $body, type: $type, priority: $priority, state: $state, created: $created, pr_url: ""}')
      local updated
      updated=$(jq ". + [$entry]" "$f")
      echo "$updated" > "$f"
      echo "$id"
      ;;
    *)
      echo "ERROR: Unknown ticketing provider '$provider'" >&2
      return 1
      ;;
  esac
}

# ─── ticket_list_by_state ───────────────────────────────────────────────
# List tickets in a given state. Returns JSON array.
ticket_list_by_state() {
  local state="$1"
  local provider
  provider=$(_ticket_provider)

  case "$provider" in
    github)
      local state_label
      state_label=$(_gh_state_label "$state")
      gh issue list --label "$state_label" --json number,title,labels,state --limit 50 2>/dev/null || echo '[]'
      ;;
    local|none)
      _ensure_local_backlog
      local f
      f=$(_local_backlog_file)
      jq --arg s "$state" '[.[] | select(.state == $s)]' "$f"
      ;;
    *)
      echo '[]'
      ;;
  esac
}

# ─── ticket_transition ──────────────────────────────────────────────────
# Transition a ticket to a new state.
ticket_transition() {
  local id="$1"
  local new_state="$2"
  local provider
  provider=$(_ticket_provider)

  # Validate state
  case "$new_state" in
    backlog|todo|in_progress|in_review|done) ;;
    *) echo "ERROR: Invalid state '$new_state'" >&2; return 1 ;;
  esac

  case "$provider" in
    github)
      # Remove old state labels, add new one
      local old_labels new_label
      new_label=$(_gh_state_label "$new_state")
      for s in backlog todo in_progress in_review "done"; do
        old_labels=$(_gh_state_label "$s")
        gh issue edit "$id" --remove-label "$old_labels" 2>/dev/null || true
      done
      gh issue edit "$id" --add-label "$new_label" 2>/dev/null || true
      # Close issue if done
      if [ "$new_state" = "done" ]; then
        gh issue close "$id" 2>/dev/null || true
      fi
      ;;
    local|none)
      _ensure_local_backlog
      local f
      f=$(_local_backlog_file)
      # Check if ticket exists
      local exists
      exists=$(jq --arg i "$id" '[.[] | select(.id == $i)] | length' "$f")
      if [ "$exists" -eq 0 ]; then
        echo "ERROR: ticket '$id' not found" >&2
        return 1
      fi
      local updated
      updated=$(jq --arg i "$id" --arg s "$new_state" 'map(if .id == $i then .state = $s else . end)' "$f")
      echo "$updated" > "$f"
      ;;
  esac
}

# ─── ticket_add_comment ─────────────────────────────────────────────────
ticket_add_comment() {
  local id="$1"
  local comment="$2"
  local provider
  provider=$(_ticket_provider)

  case "$provider" in
    github)
      gh issue comment "$id" --body "$comment" 2>/dev/null || true
      ;;
    local|none)
      # Append to notes field in local backlog
      _ensure_local_backlog
      local f
      f=$(_local_backlog_file)
      # Check if ticket exists
      local exists
      exists=$(jq --arg i "$id" '[.[] | select(.id == $i)] | length' "$f")
      if [ "$exists" -eq 0 ]; then
        echo "ERROR: ticket '$id' not found" >&2
        return 1
      fi
      local updated
      updated=$(jq --arg i "$id" --arg c "$comment" 'map(if .id == $i then .notes = ((.notes // "") | if . == "" then $c else . + "\n" + $c end) else . end)' "$f")
      echo "$updated" > "$f"
      ;;
  esac
}

# ─── ticket_get ────────────────────────────────────────────────────────
# Retrieve a single ticket by ID. Returns the full JSON object.
# Args: id
ticket_get() {
  local id="$1"
  local provider
  provider=$(_ticket_provider)

  case "$provider" in
    github)
      gh issue view "$id" --json number,title,body,labels,state 2>/dev/null || { echo "ERROR: issue #$id not found" >&2; return 1; }
      ;;
    local|none)
      _ensure_local_backlog
      local f
      f=$(_local_backlog_file)
      local result
      result=$(jq --arg i "$id" '.[] | select(.id == $i)' "$f")
      if [ -z "$result" ]; then
        echo "ERROR: ticket '$id' not found" >&2
        return 1
      fi
      echo "$result"
      ;;
    *)
      echo "ERROR: Unknown ticketing provider '$provider'" >&2
      return 1
      ;;
  esac
}

# ─── ticket_set_pr_url ─────────────────────────────────────────────────
# Associate a PR URL with a ticket.
# Args: id url
ticket_set_pr_url() {
  local id="$1"
  local url="$2"
  local provider
  provider=$(_ticket_provider)

  case "$provider" in
    github)
      # GitHub issues don't have a pr_url field; the link is implicit via PR body references.
      # This is a no-op for github provider.
      ;;
    local|none)
      _ensure_local_backlog
      local f
      f=$(_local_backlog_file)
      local exists
      exists=$(jq --arg i "$id" '[.[] | select(.id == $i)] | length' "$f")
      if [ "$exists" -eq 0 ]; then
        echo "ERROR: ticket '$id' not found" >&2
        return 1
      fi
      local updated
      updated=$(jq --arg i "$id" --arg u "$url" 'map(if .id == $i then .pr_url = $u else . end)' "$f")
      echo "$updated" > "$f"
      ;;
    *)
      echo "ERROR: Unknown ticketing provider '$provider'" >&2
      return 1
      ;;
  esac
}

# ─── ticket_extract_ids_from_pr ──────────────────────────────────────────
# Parse PR body for ticket references. Returns newline-separated IDs.
ticket_extract_ids_from_pr() {
  local pr_number="$1"
  local provider
  provider=$(_ticket_provider)

  case "$provider" in
    github)
      # Look for "Fixes #N", "Closes #N", "Resolves #N", or bare "#N" in PR body
      local body
      body=$(gh pr view "$pr_number" --json body -q '.body' 2>/dev/null || echo "")
      echo "$body" | grep -oE '#[0-9]+' | sed 's/#//' | sort -u
      ;;
    local|none)
      # Look for "Ticket: ID" pattern in PR body
      local body
      body=$(gh pr view "$pr_number" --json body -q '.body' 2>/dev/null || echo "")
      echo "$body" | grep -oE 'Ticket: [0-9]+' | sed 's/Ticket: //' | sort -u
      ;;
  esac
}

# ─── ticket_recover_stale ───────────────────────────────────────────────
# Find in_progress tickets without open PRs, move back to todo.
ticket_recover_stale() {
  local provider
  provider=$(_ticket_provider)

  case "$provider" in
    github)
      local in_progress_label
      in_progress_label=$(_gh_state_label "in_progress")
      local issues
      issues=$(gh issue list --label "$in_progress_label" --json number --limit 50 2>/dev/null || echo '[]')
      local count
      count=$(echo "$issues" | jq length)
      local recovered=0
      for i in $(seq 0 $((count - 1))); do
        local issue_num
        issue_num=$(echo "$issues" | jq -r ".[$i].number")
        # Check if any open PR references this issue
        local open_prs
        open_prs=$(gh pr list --search "$issue_num" --json number --limit 1 2>/dev/null || echo '[]')
        if [ "$(echo "$open_prs" | jq length)" -eq 0 ]; then
          echo "  [tickets] Recovering stale issue #$issue_num (in_progress with no open PR)"
          ticket_transition "$issue_num" "todo"
          recovered=$((recovered + 1))
        fi
      done
      echo "  [tickets] Recovered $recovered stale ticket(s)"
      ;;
    local|none)
      _ensure_local_backlog
      local f
      f=$(_local_backlog_file)
      local updated
      updated=$(jq '[.[] | if .state == "in_progress" and .pr_url == "" then .state = "todo" else . end]' "$f")
      echo "$updated" > "$f"
      ;;
  esac
}

# ─── ticket_count_by_state ──────────────────────────────────────────────
# Count tickets in a given state. Returns integer.
ticket_count_by_state() {
  local state="$1"
  local provider
  provider=$(_ticket_provider)

  case "$provider" in
    github)
      local state_label
      state_label=$(_gh_state_label "$state")
      gh issue list --label "$state_label" --json number --limit 100 2>/dev/null | jq length 2>/dev/null || echo 0
      ;;
    local|none)
      _ensure_local_backlog
      local f
      f=$(_local_backlog_file)
      jq --arg s "$state" '[.[] | select(.state == $s)] | length' "$f"
      ;;
    *)
      echo 0
      ;;
  esac
}
