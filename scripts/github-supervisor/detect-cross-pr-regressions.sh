#!/bin/bash
# Cross-PR Regression Detector
#
# Detects when merged PRs accidentally undo each other's work:
# - Files added by one PR and deleted by another
# - Lines reverted (same content changed back)
# - Conflicting modifications to the same files within a window
#
# This is a deterministic (Stage 1) analysis using only git history.
# It does NOT require AI — it's pure git log + diff analysis.
#
# Usage:
#   ./detect-cross-pr-regressions.sh                    # Last 7 days
#   ./detect-cross-pr-regressions.sh --days 14          # Last 14 days
#   ./detect-cross-pr-regressions.sh --since 2026-03-01 # Since specific date
#   ./detect-cross-pr-regressions.sh --json             # JSON output
#
# Exit codes:
#   0 - No regressions detected
#   1 - Regressions detected
#   2 - Usage error

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────
DAYS=7
SINCE=""
BASE_BRANCH="${BASE_BRANCH:-main}"
JSON_OUTPUT=false
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# ── Parse arguments ───────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --days)     DAYS="$2"; shift 2 ;;
    --days=*)   DAYS="${1#*=}"; shift ;;
    --since)    SINCE="$2"; shift 2 ;;
    --since=*)  SINCE="${1#*=}"; shift ;;
    --branch)   BASE_BRANCH="$2"; shift 2 ;;
    --json)     JSON_OUTPUT=true; shift ;;
    --help|-h)
      echo "Usage: $0 [--days N] [--since DATE] [--branch BRANCH] [--json]"
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 2 ;;
  esac
done

if [ -z "$SINCE" ]; then
  SINCE=$(date -v-${DAYS}d +%Y-%m-%d 2>/dev/null || date -d "$DAYS days ago" +%Y-%m-%d 2>/dev/null || echo "")
  if [ -z "$SINCE" ]; then
    echo "ERROR: Could not compute date. Use --since YYYY-MM-DD" >&2
    exit 2
  fi
fi

# ── Fetch latest ──────────────────────────────────────────────────────
git -C "$REPO_ROOT" fetch origin "$BASE_BRANCH" --quiet 2>/dev/null || true

# ── Find merge commits in the window ─────────────────────────────────
MERGE_COMMITS=$(git -C "$REPO_ROOT" log --merges --format='%H' \
  --after="$SINCE" "origin/$BASE_BRANCH" 2>/dev/null || echo "")

if [ -z "$MERGE_COMMITS" ]; then
  [ "$JSON_OUTPUT" = true ] && echo '{"regressions":[],"since":"'"$SINCE"'","merge_count":0}'
  exit 0
fi

MERGE_COUNT=$(echo "$MERGE_COMMITS" | wc -l | tr -d ' ')

# ── Stage 1: Detect add-then-delete patterns ─────────────────────────
# For each file added in the window, check if it was later deleted
REGRESSIONS=()

# Get all files added and deleted in the window
ADDED_FILES=$(git -C "$REPO_ROOT" log --diff-filter=A --name-only --format="" \
  --after="$SINCE" "origin/$BASE_BRANCH" 2>/dev/null | sort -u || echo "")
DELETED_FILES=$(git -C "$REPO_ROOT" log --diff-filter=D --name-only --format="" \
  --after="$SINCE" "origin/$BASE_BRANCH" 2>/dev/null | sort -u || echo "")

if [ -n "$ADDED_FILES" ] && [ -n "$DELETED_FILES" ]; then
  ADD_THEN_DELETE=$(comm -12 <(echo "$ADDED_FILES") <(echo "$DELETED_FILES") || echo "")
  while IFS= read -r file; do
    [ -z "$file" ] && continue

    # Find which commit added it and which deleted it
    added_by=$(git -C "$REPO_ROOT" log --diff-filter=A --format='%H %s' \
      --after="$SINCE" "origin/$BASE_BRANCH" -- "$file" 2>/dev/null | head -1 || echo "")
    deleted_by=$(git -C "$REPO_ROOT" log --diff-filter=D --format='%H %s' \
      --after="$SINCE" "origin/$BASE_BRANCH" -- "$file" 2>/dev/null | head -1 || echo "")

    if [ -n "$added_by" ] && [ -n "$deleted_by" ]; then
      REGRESSIONS+=("ADD_THEN_DELETE|$file|$added_by|$deleted_by")
    fi
  done <<< "$ADD_THEN_DELETE"
fi

# ── Stage 1b: Detect revert patterns ─────────────────────────────────
# Look for commits whose message mentions "revert" in the window
REVERT_COMMITS=$(git -C "$REPO_ROOT" log --format='%H %s' \
  --after="$SINCE" "origin/$BASE_BRANCH" 2>/dev/null \
  | grep -iE 'revert|undo|rollback' || echo "")

while IFS= read -r line; do
  [ -z "$line" ] && continue
  commit_sha=$(echo "$line" | cut -d' ' -f1)
  commit_msg=$(echo "$line" | cut -d' ' -f2-)
  REGRESSIONS+=("REVERT|$commit_sha|$commit_msg")
done <<< "$REVERT_COMMITS"

# ── Stage 1c: Detect high-churn files ────────────────────────────────
# Files modified by 3+ separate merge commits may indicate conflicting changes
HIGH_CHURN=$(git -C "$REPO_ROOT" log --merges --name-only --format="" \
  --after="$SINCE" "origin/$BASE_BRANCH" 2>/dev/null \
  | sort | uniq -c | sort -rn | awk '$1 >= 3 {print $1, $2}' || echo "")

while IFS= read -r line; do
  [ -z "$line" ] && continue
  count=$(echo "$line" | awk '{print $1}')
  file=$(echo "$line" | awk '{print $2}')
  REGRESSIONS+=("HIGH_CHURN|$file|modified_by_${count}_merges")
done <<< "$HIGH_CHURN"

# ── Output ────────────────────────────────────────────────────────────
REGRESSION_COUNT=${#REGRESSIONS[@]}

if [ "$JSON_OUTPUT" = true ]; then
  echo '{"since":"'"$SINCE"'","merge_count":'"$MERGE_COUNT"',"regression_count":'"$REGRESSION_COUNT"',"regressions":['
  first=true
  for r in "${REGRESSIONS[@]+"${REGRESSIONS[@]}"}"; do
    [ "$first" = true ] && first=false || echo ","
    type=$(echo "$r" | cut -d'|' -f1)
    detail=$(echo "$r" | cut -d'|' -f2-)
    echo '  {"type":"'"$type"'","detail":"'"$detail"'"}'
  done
  echo ']}'
else
  echo "Cross-PR Regression Report"
  echo "=========================="
  echo "  Period: $SINCE to now"
  echo "  Branch: $BASE_BRANCH"
  echo "  Merge commits: $MERGE_COUNT"
  echo "  Regressions found: $REGRESSION_COUNT"
  echo ""

  if [ "$REGRESSION_COUNT" -eq 0 ]; then
    echo "  No regressions detected."
  else
    for r in "${REGRESSIONS[@]}"; do
      type=$(echo "$r" | cut -d'|' -f1)
      case "$type" in
        ADD_THEN_DELETE)
          file=$(echo "$r" | cut -d'|' -f2)
          added=$(echo "$r" | cut -d'|' -f3)
          deleted=$(echo "$r" | cut -d'|' -f4)
          echo "  [ADD_THEN_DELETE] $file"
          echo "    Added by:   $added"
          echo "    Deleted by: $deleted"
          echo ""
          ;;
        REVERT)
          sha=$(echo "$r" | cut -d'|' -f2)
          msg=$(echo "$r" | cut -d'|' -f3)
          echo "  [REVERT] $sha $msg"
          echo ""
          ;;
        HIGH_CHURN)
          file=$(echo "$r" | cut -d'|' -f2)
          detail=$(echo "$r" | cut -d'|' -f3)
          echo "  [HIGH_CHURN] $file ($detail)"
          echo ""
          ;;
      esac
    done
  fi
fi

[ "$REGRESSION_COUNT" -gt 0 ] && exit 1 || exit 0
