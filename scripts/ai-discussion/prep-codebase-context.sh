#!/usr/bin/env bash
# prep-codebase-context.sh
#
# Generate a compact codebase context block for AI discussions.
# Reads the most relevant files for a given topic and prints them to stdout
# in a format suitable for passing to discuss.py --context.
#
# Usage:
#   # Default: architecture overview
#   scripts/ai-discussion/prep-codebase-context.sh
#
#   # Specific topic
#   scripts/ai-discussion/prep-codebase-context.sh architecture
#
#   # Use in a discussion:
#   CTX=$(scripts/ai-discussion/prep-codebase-context.sh architecture)
#   python scripts/ai-discussion/discuss.py "topic" \
#     --context "$CTX" --create-only
#
#   # Or with --codebase-files (injects full file content per-turn):
#   python scripts/ai-discussion/discuss.py "topic" \
#     --codebase-files whitepaper.md \
#                      scripts/kitchenloop/kitchenloop.sh \
#     --create-only
#
# Notes:
#   - --context: one-time summary at conversation creation. Good for all debaters.
#   - --codebase-files: injected into every turn prompt. More complete but larger.
#     For Gemini: treated as a guided file list (Gemini has autonomous file tools).
#     For Codex/Claude: file contents are embedded directly in the prompt.
#
# CUSTOMIZATION:
#   Add your own topic keywords and file mappings below. The defaults reference
#   the Kitchen Loop framework structure. Adapt the file paths to match your
#   project's layout (blueprints, docs, source directories, etc.).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || cd "$(dirname "$0")/../.." && pwd)"
TOPIC="${1:-architecture}"

# Map topic keywords to relevant files.
# CUSTOMIZE: Replace these with your project's key files.
declare -a FILES=()

case "$TOPIC" in
  architecture|arch*)
    FILES=(
      "whitepaper.md"
      "scripts/kitchenloop/kitchenloop.sh"
    )
    ;;
  loop|kitchenloop)
    FILES=(
      "scripts/kitchenloop/kitchenloop.sh"
      "scripts/kitchenloop/prompts/ideate.md"
      "scripts/kitchenloop/prompts/execute.md"
    )
    ;;
  prompts|skills)
    FILES=(
      "scripts/kitchenloop/prompts/ideate.md"
      "scripts/kitchenloop/prompts/triage.md"
      "scripts/kitchenloop/prompts/execute.md"
      "scripts/kitchenloop/prompts/polish.md"
      "scripts/kitchenloop/prompts/regress.md"
      "scripts/kitchenloop/prompts/backlog.md"
    )
    ;;
  discussion|debate)
    FILES=(
      "scripts/ai-discussion/discuss.py"
      ".claude/skills/discussion-moderator/SKILL.md"
    )
    ;;
  *)
    # Default: core files
    FILES=(
      "whitepaper.md"
      "scripts/kitchenloop/kitchenloop.sh"
    )
    ;;
esac

echo "=== CODEBASE CONTEXT ==="
echo "Repository: $REPO_ROOT"
echo "Topic: $TOPIC"
echo ""
echo "Key files for this discussion:"
echo ""

for f in "${FILES[@]}"; do
  fullpath="$REPO_ROOT/$f"
  if [[ -f "$fullpath" ]]; then
    echo "--- $f ---"
    # Print first 100 lines of each file (compact summary)
    head -100 "$fullpath"
    echo ""
  else
    echo "--- $f [not found] ---"
    echo ""
  fi
done

echo "=== END CODEBASE CONTEXT ==="
echo ""
echo "For deeper access, use --codebase-files with specific file paths."
echo "Gemini has autonomous file tools and can read any file in the repo."
