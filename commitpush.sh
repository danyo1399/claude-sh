#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# commitpush.sh
# AI-powered commit & push:
#   1. Stage all changes, generate a conventional commit message, commit
#   2. Push to remote
#
# Usage:
#   commitpush.sh [--no-push] [--model MODEL]
# -------------------------------------------------------------------

# ── Defaults & configuration ──────────────────────────────────────
CLAUDE_CMD="${CLAUDE_CMD:-claude}"
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-sonnet-4-6}"
NO_PUSH=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-push)  NO_PUSH=1; shift ;;
    --model)    CLAUDE_MODEL="$2"; shift 2 ;;
    -h|--help)
      sed -n '3,/^# ---$/p' "$0" | head -n -1 | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "ERROR: must be run inside a git repository." >&2
  exit 1
}

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || {
  echo "ERROR: no commits on current branch." >&2
  exit 1
}

if [ "$CURRENT_BRANCH" = "HEAD" ]; then
  echo "ERROR: detached HEAD state. Cannot commit." >&2
  exit 1
fi

# Check there are actually changes to commit
if git diff --quiet && git diff --cached --quiet && [ -z "$(git ls-files --others --exclude-standard)" ]; then
  echo "Nothing to commit — working tree is clean."
  exit 0
fi

echo "── Commit & Push ──────────────────────────────────────────"
echo "  Repo root      : ${REPO_ROOT}"
echo "  Current branch : ${CURRENT_BRANCH}"
echo "  Claude cmd     : ${CLAUDE_CMD}"
echo "  Model          : ${CLAUDE_MODEL}"
echo "──────────────────────────────────────────────────────────"
echo ""

# ══════════════════════════════════════════════════════════════════
# STEP 1: Stage all changes, generate commit message, commit
# ══════════════════════════════════════════════════════════════════
echo "── Step 1/2: Committing ─────────────────────────────────"
echo ""

cd "$REPO_ROOT"
git add -A

PROMPT_CONTEXT="CONTEXT:
- Repository root: ${REPO_ROOT}
- Current branch: ${CURRENT_BRANCH}"

PROMPT_BODY=$(cat <<'PROMPT_EOF'

You are generating a git commit message for staged changes.

INSTRUCTIONS:

1. Run `git diff --cached` and `git diff --cached --stat` to understand what is staged.

2. Write a single conventional commit message for all the staged changes.
   - Format: `type(scope): description`
   - Types: feat, fix, refactor, docs, style, test, chore, ci, perf, build
   - Scope is optional but recommended
   - Description should be imperative, lowercase, no period at the end
   - Keep the first line under 72 characters
   - If the changes need more explanation, add a body after a blank line

3. Commit the changes using `git commit -m "<your message>"`. If the message has a body, use multiple -m flags or a heredoc.

4. Your ONLY deliverable is creating the git commit. Do NOT write any files.
PROMPT_EOF
)

PROMPT_COMMIT="${PROMPT_CONTEXT}
${PROMPT_BODY}"

if ! $CLAUDE_CMD -p "$PROMPT_COMMIT" --model "$CLAUDE_MODEL" --dangerously-skip-permissions < /dev/null; then
  echo "ERROR: Step 1 failed — claude exited with a non-zero status." >&2
  exit 1
fi

echo ""

# ══════════════════════════════════════════════════════════════════
# STEP 2: Push
# ══════════════════════════════════════════════════════════════════
if [ "$NO_PUSH" -eq 1 ]; then
  echo "── Skipping push (--no-push) ────────────────────────────"
else
  echo "── Step 2/2: Pushing to ${CURRENT_BRANCH} ──────────────"
  if ! git push -u origin "$CURRENT_BRANCH"; then
    echo "ERROR: push failed." >&2
    exit 1
  fi
fi

echo ""
echo "── Complete ───────────────────────────────────────────────"
git log --oneline -1
echo "──────────────────────────────────────────────────────────"
