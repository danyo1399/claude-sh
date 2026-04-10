#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# ocgitcommit.sh
# AI-powered git commit pipeline (OpenCode):
#   Staged/All mode — AI generates commit message → script commits
#   Smart mode      — AI groups changes into logical commits
# -------------------------------------------------------------------

usage() {
  cat <<EOF
AI-powered git commit that analyzes your changes and generates
meaningful commit messages. Supports single commits or intelligent
multi-commit grouping.

Usage: ocgitcommit.sh [OPTIONS]

Options:
  -h, --help             Show this help message and exit
  --model MODEL          OpenCode model to use (e.g. opencode/claude-sonnet-4-6)
  --opencode-cmd CMD     Path to opencode binary (default: opencode)
  --staged               Commit staged changes only (default)
  --all                  Stage and commit all pending changes
  --smart                AI groups changes into logical commits
  --push                 Push to origin after committing
  --context "TEXT"       Additional context for commit message generation

Environment variables:
  OPENCODE_CMD           Path to opencode binary (default: opencode)
  OPENCODE_MODEL         Model override (e.g. opencode/claude-sonnet-4-6); --model flag takes precedence
  KEEP_WORK_DIR          Set to 1 to preserve temp files on failure

Examples:
  ocgitcommit.sh                              # commit staged changes
  ocgitcommit.sh --all                        # stage and commit everything
  ocgitcommit.sh --smart                      # AI creates logical commits
  ocgitcommit.sh --staged --push              # commit staged and push
  ocgitcommit.sh --all --context "refactored auth module"
  ocgitcommit.sh --smart --push --context "feature: user dashboard"
EOF
}

# ── Parse options ────────────────────────────────────────────────
OPENCODE_CMD="${OPENCODE_CMD:-opencode}"
OPENCODE_MODEL="${OPENCODE_MODEL:-}"
COMMIT_MODE="staged"
PUSH=false
USER_CONTEXT=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --model)
      OPENCODE_MODEL="$2"
      shift 2
      ;;
    --opencode-cmd)
      OPENCODE_CMD="$2"
      shift 2
      ;;
    --staged)
      COMMIT_MODE="staged"
      shift
      ;;
    --all)
      COMMIT_MODE="all"
      shift
      ;;
    --smart)
      COMMIT_MODE="smart"
      shift
      ;;
    --push)
      PUSH=true
      shift
      ;;
    --context)
      USER_CONTEXT="$2"
      shift 2
      ;;
    -*)
      echo "ERROR: unknown option '$1'" >&2
      echo "  Run 'ocgitcommit.sh --help' for usage." >&2
      exit 1
      ;;
    *)
      echo "ERROR: unexpected argument '$1'" >&2
      echo "  Run 'ocgitcommit.sh --help' for usage." >&2
      exit 1
      ;;
  esac
done

# ── Git validation ───────────────────────────────────────────────
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "ERROR: must be run inside a git repository." >&2
  exit 1
}

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || {
  echo "ERROR: no commits on current branch." >&2
  exit 1
}

if [ "$CURRENT_BRANCH" = "HEAD" ]; then
  CURRENT_BRANCH="detached at $(git rev-parse --short HEAD)"
  echo "WARNING: detached HEAD state." >&2
fi

# ── Commit mode setup ───────────────────────────────────────────
case "$COMMIT_MODE" in
  staged)
    if git diff --cached --quiet; then
      echo "ERROR: no staged changes to commit." >&2
      exit 1
    fi
    COMMIT_LABEL="staged changes"
    ;;
  all)
    if [ -z "$(git status --porcelain)" ]; then
      echo "ERROR: no pending changes to commit." >&2
      exit 1
    fi
    COMMIT_LABEL="all pending changes"
    ;;
  smart)
    if [ -z "$(git status --porcelain)" ]; then
      echo "ERROR: no pending changes to commit." >&2
      exit 1
    fi
    COMMIT_LABEL="smart grouping"
    ;;
esac

# ── Working directory ────────────────────────────────────────────
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
WORK_DIR="${TMPDIR%/}/ocgitcommit-${RUN_ID}"
mkdir -p "$WORK_DIR"

cleanup() {
  if [ "${KEEP_WORK_DIR:-0}" != "1" ] && [ -d "${WORK_DIR:-}" ]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

LOG_FILE="${WORK_DIR}/opencode.log"
COMMIT_MSG_FILE="${WORK_DIR}/commit-message.txt"

# run_opencode PROMPT [STDOUT_FILE]
#   Runs opencode run, tees stdout to LOG_FILE (and optional STDOUT_FILE),
#   captures stderr, and reports diagnostics on failure.
run_opencode() {
  local prompt="$1"
  local stdout_file="${2:-}"
  local exit_code=0
  local stderr_file="${WORK_DIR}/opencode-stderr.tmp"

  local model_args=()
  if [ -n "$OPENCODE_MODEL" ]; then
    model_args=(--model "$OPENCODE_MODEL")
  fi

  if [ -n "$stdout_file" ]; then
    $OPENCODE_CMD run "$prompt" ${model_args[@]+"${model_args[@]}"} --dangerously-skip-permissions \
      < /dev/null 2>"$stderr_file" | tee -a "$LOG_FILE" > "$stdout_file" || exit_code=$?
  else
    $OPENCODE_CMD run "$prompt" ${model_args[@]+"${model_args[@]}"} --dangerously-skip-permissions \
      < /dev/null 2>"$stderr_file" | tee -a "$LOG_FILE" || exit_code=$?
  fi

  if [ -s "$stderr_file" ]; then
    echo "" >> "$LOG_FILE"
    echo "── stderr ──" >> "$LOG_FILE"
    cat "$stderr_file" >> "$LOG_FILE"
    echo "  OpenCode stderr:" >&2
    cat "$stderr_file" >&2
  fi
  rm -f "$stderr_file"

  return "$exit_code"
}

# ── Banner ───────────────────────────────────────────────────────
CONTEXT_DISPLAY="${USER_CONTEXT:-<none>}"
echo "── Git Commit Pipeline (OpenCode) ───────────────────────"
echo "  Repo root      : ${REPO_ROOT}"
echo "  Current branch : ${CURRENT_BRANCH}"
echo "  Commit mode    : ${COMMIT_LABEL}"
echo "  Push           : ${PUSH}"
echo "  Context        : ${CONTEXT_DISPLAY}"
echo "  OpenCode cmd   : ${OPENCODE_CMD}"
echo "  Model          : ${OPENCODE_MODEL:-<default>}"
echo "  Working dir    : ${WORK_DIR}"
echo "  Log file       : ${LOG_FILE}"
echo "───────────────────────────────────────────────────────────"
echo ""

# Build optional context instruction for prompts
CONTEXT_INSTRUCTION=""
if [ -n "$USER_CONTEXT" ]; then
  CONTEXT_INSTRUCTION="- Additional context from user: ${USER_CONTEXT}"
fi

if [ "$COMMIT_MODE" = "smart" ]; then
  # ══════════════════════════════════════════════════════════════
  # SMART MODE: AI analyses, groups, and commits
  # ══════════════════════════════════════════════════════════════
  echo "── Step 1/1: Analyse & Commit ─────────────────────────"
  echo ""

  HEAD_BEFORE="$(git rev-parse HEAD)"

  PROMPT_CONTEXT="CONTEXT:
- Repository root: ${REPO_ROOT}
- Current branch: ${CURRENT_BRANCH}
${CONTEXT_INSTRUCTION}"

  PROMPT_BODY=$(cat <<'PROMPT_EOF'

You are an expert at organizing code changes into clean, logical git commits.

INSTRUCTIONS:

Examine all uncommitted changes in the repository (staged, unstaged, and untracked files). Use `git status`, `git diff`, `git diff --cached`, and read files as needed to understand every change.

Group the changes into logical commits. Each commit should represent a single coherent unit of work (e.g., a feature, a bug fix, a refactor, a config change). Consider:
- Files that change together for the same reason belong in the same commit
- Separate functional changes from formatting or cleanup changes
- Separate unrelated features or fixes into distinct commits
- If all changes are related, a single commit is fine — do not split artificially

For each logical group, in order:
1. Unstage everything first with `git reset HEAD` (only before the first group)
2. Stage only the files for that group with `git add <files>`
3. Commit with a clear message

Commit message rules:
- Use conventional commit format: type(scope): description
- Common types: feat, fix, refactor, docs, style, test, chore, build, ci
- First line MUST be under 72 characters
- Add a body separated by a blank line for complex changes
- NEVER mention AI, Claude, OpenCode, or any AI tool in the commit message
- Focus on WHAT changed and WHY, not HOW

After all commits are made, print a short summary listing each commit (hash and message).
PROMPT_EOF
  )

  FULL_PROMPT="${PROMPT_CONTEXT}
${PROMPT_BODY}"

  if ! run_opencode "$FULL_PROMPT"; then
    echo "ERROR: Smart commit failed — opencode exited with a non-zero status." >&2
    echo "  See log: ${LOG_FILE}" >&2
    exit 1
  fi

  HEAD_AFTER="$(git rev-parse HEAD)"
  if [ "$HEAD_BEFORE" = "$HEAD_AFTER" ]; then
    echo "ERROR: Smart commit failed — no commits were created." >&2
    echo "  See log: ${LOG_FILE}" >&2
    exit 1
  fi
  echo ""

else
  # ══════════════════════════════════════════════════════════════
  # STAGED / ALL MODE: AI generates message → script commits
  # ══════════════════════════════════════════════════════════════

  # For --all mode, stage everything before generating the message
  if [ "$COMMIT_MODE" = "all" ]; then
    git add -A
  fi

  echo "── Step 1/1: Generate Commit Message ──────────────────"
  echo ""

  PROMPT_CONTEXT="CONTEXT:
- Repository root: ${REPO_ROOT}
- Current branch: ${CURRENT_BRANCH}
- Commit message output file: ${COMMIT_MSG_FILE}
${CONTEXT_INSTRUCTION}"

  PROMPT_BODY=$(cat <<'PROMPT_EOF'

You are an expert at writing clear, informative git commit messages.

INSTRUCTIONS:

Examine the staged changes using `git diff --cached`. Read relevant files for additional context if needed.

Generate a commit message and write it to the commit message output file listed above.

Commit message rules:
- Use conventional commit format: type(scope): description
- Common types: feat, fix, refactor, docs, style, test, chore, build, ci
- First line MUST be under 72 characters
- Add a body separated by a blank line for complex changes
- NEVER mention AI, Claude, OpenCode, or any AI tool in the commit message
- Focus on WHAT changed and WHY, not HOW
- If additional context was provided by the user, factor it into the message

Your ONLY deliverable is writing the commit message to the output file. Write ONLY the raw commit message — no markdown fences, no commentary, no extra formatting.
PROMPT_EOF
  )

  FULL_PROMPT="${PROMPT_CONTEXT}
${PROMPT_BODY}"

  if ! run_opencode "$FULL_PROMPT"; then
    echo "ERROR: Commit message generation failed — opencode exited with a non-zero status." >&2
    echo "  See log: ${LOG_FILE}" >&2
    exit 1
  fi

  if [ ! -s "$COMMIT_MSG_FILE" ]; then
    echo "ERROR: Commit message generation failed — ${COMMIT_MSG_FILE} is empty or missing." >&2
    echo "  See log: ${LOG_FILE}" >&2
    exit 1
  fi

  echo ""
  echo "  Commit message:"
  echo "  ────────────────"
  sed 's/^/  /' "$COMMIT_MSG_FILE"
  echo "  ────────────────"
  echo ""

  if ! git commit -F "$COMMIT_MSG_FILE"; then
    echo "ERROR: git commit failed." >&2
    exit 1
  fi
  echo ""
fi

# ── Optional push ────────────────────────────────────────────────
if [ "$PUSH" = true ]; then
  PUSH_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  if [ "$PUSH_BRANCH" = "HEAD" ]; then
    echo "ERROR: cannot push in detached HEAD state." >&2
    exit 1
  fi
  echo "── Pushing to origin ──────────────────────────────────"
  if ! git push origin "$PUSH_BRANCH"; then
    echo "ERROR: git push failed." >&2
    exit 1
  fi
  echo ""
fi

# ══════════════════════════════════════════════════════════════════
# Done
# ══════════════════════════════════════════════════════════════════
trap - EXIT
echo "── Git Commit Complete ────────────────────────────────────"
echo "  Log file       : ${LOG_FILE}"
echo "───────────────────────────────────────────────────────────"
