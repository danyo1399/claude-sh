#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# cxprdescription.sh
# AI pull request description pipeline (Codex):
#   1. Analyse branch changes and generate PR title + description
#      with change summary, manual testing areas, and risk rating
# -------------------------------------------------------------------

usage() {
  cat <<EOF
Compares two branches and generates a pull request title and description.
The description includes a summary of changes, areas requiring manual
testing, and a risk rating.

Usage: cxprdescription.sh [OPTIONS] [BASE_BRANCH]

Arguments:
  BASE_BRANCH          Branch to diff against (default: main)

Options:
  -h, --help           Show this help message and exit
  --model MODEL        Codex model to use (e.g. gpt-5-codex)
  --codex-cmd CMD      Path to codex binary (default: codex)

Environment variables:
  CODEX_CMD            Path to codex binary (default: codex); --codex-cmd takes precedence
  CODEX_MODEL          Model override (e.g. gpt-5-codex); --model flag takes precedence
  KEEP_WORK_DIR        Set to 1 to preserve temp files on failure

Examples:
  cxprdescription.sh                        # compare current branch vs main
  cxprdescription.sh develop                # compare current branch vs develop
  cxprdescription.sh --model gpt-5-codex main
EOF
}

# ── Parse options ────────────────────────────────────────────────
CODEX_CMD="${CODEX_CMD:-codex}"
CODEX_MODEL="${CODEX_MODEL:-}"
BASE_BRANCH=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --model)
      CODEX_MODEL="$2"
      shift 2
      ;;
    --codex-cmd)
      CODEX_CMD="$2"
      shift 2
      ;;
    -*)
      echo "ERROR: unknown option '$1'" >&2
      echo "  Run 'cxprdescription.sh --help' for usage." >&2
      exit 1
      ;;
    *)
      BASE_BRANCH="$1"
      shift
      ;;
  esac
done

BASE_BRANCH="${BASE_BRANCH:-main}"

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
  echo "WARNING: detached HEAD state. Using: ${CURRENT_BRANCH}" >&2
fi

if ! git rev-parse --verify "${BASE_BRANCH}" >/dev/null 2>&1; then
  echo "ERROR: base branch '${BASE_BRANCH}' does not exist." >&2
  exit 1
fi

MERGE_BASE="$(git merge-base "${BASE_BRANCH}" HEAD 2>/dev/null)" || true
HEAD_SHA="$(git rev-parse HEAD)"
if [ "$MERGE_BASE" = "$HEAD_SHA" ]; then
  echo "ERROR: no commits between '${CURRENT_BRANCH}' and '${BASE_BRANCH}'." >&2
  exit 1
fi

# ── Working directory ───────────────────────────────────────────
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
WORK_DIR="${TMPDIR:-/tmp}"
WORK_DIR="${WORK_DIR%/}/cx-pr-description-${RUN_ID}"
mkdir -p "$WORK_DIR"

cleanup() {
  if [ "${KEEP_WORK_DIR:-0}" != "1" ] && [ -d "${WORK_DIR:-}" ]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

OUTPUT_FILE="${WORK_DIR}/PR_DESCRIPTION.md"
LOG_FILE="${WORK_DIR}/codex.log"

# run_codex PROMPT [STDOUT_FILE]
#   Runs codex exec, tees stdout to LOG_FILE (and optional STDOUT_FILE),
#   captures stderr, and reports diagnostics on failure.
run_codex() {
  local prompt="$1"
  local stdout_file="${2:-}"
  local exit_code=0
  local stderr_file="${WORK_DIR}/codex-stderr.tmp"

  local model_args=()
  if [ -n "$CODEX_MODEL" ]; then
    model_args=(--model "$CODEX_MODEL")
  fi

  if [ -n "$stdout_file" ]; then
    $CODEX_CMD exec "$prompt" ${model_args[@]+"${model_args[@]}"} \
      --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check \
      < /dev/null 2>"$stderr_file" | tee -a "$LOG_FILE" > "$stdout_file" || exit_code=$?
  else
    $CODEX_CMD exec "$prompt" ${model_args[@]+"${model_args[@]}"} \
      --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check \
      < /dev/null 2>"$stderr_file" | tee -a "$LOG_FILE" || exit_code=$?
  fi

  if [ -s "$stderr_file" ]; then
    echo "" >> "$LOG_FILE"
    echo "── stderr ──" >> "$LOG_FILE"
    cat "$stderr_file" >> "$LOG_FILE"
    echo "  Codex stderr:" >&2
    cat "$stderr_file" >&2
  fi
  rm -f "$stderr_file"

  return "$exit_code"
}

echo "── PR Description Pipeline (Codex) ───────────────────────"
echo "  Repo root      : ${REPO_ROOT}"
echo "  Current branch : ${CURRENT_BRANCH}"
echo "  Base branch    : ${BASE_BRANCH}"
echo "  Codex cmd      : ${CODEX_CMD}"
echo "  Model          : ${CODEX_MODEL:-<default>}"
echo "  Working dir    : ${WORK_DIR}"
echo "  Log file       : ${LOG_FILE}"
echo "────────────────────────────────────────────────────────────"
echo ""

# ══════════════════════════════════════════════════════════════════
# STEP 1: Generate PR Description
# ══════════════════════════════════════════════════════════════════
echo "── Step 1/1: Generate PR Description ─────────────────────"
echo ""

PROMPT_CONTEXT="CONTEXT:
- Repository root: ${REPO_ROOT}
- Current branch: ${CURRENT_BRANCH}
- Base branch: ${BASE_BRANCH}
- Output file: ${OUTPUT_FILE}"

PROMPT_BODY=$(cat <<'PROMPT_EOF'

You are an expert software engineer generating a pull request title and description.

INSTRUCTIONS:

Examine the changes between the current branch and the base branch. Run these git commands:
- git diff <base_branch>...HEAD — to see all code changes
- git log <base_branch>..HEAD --oneline — to see commit history
- Read any relevant source files to fully understand the changes

Research the codebase to understand the context and impact of the changes.

Your ONLY deliverable is writing the output file listed above. The file must be in markdown with the following structure:

## Output Format

```
# PR Title

<A concise PR title under 70 characters. Use imperative mood (e.g. "Add user authentication", "Fix race condition in queue processor").>

## Description

<A clear summary of what this PR does and why. Describe the motivation, the approach taken, and the key changes. Group related changes logically. Mention any important design decisions or trade-offs.>

## Changes

<A bulleted list of the specific changes made, grouped by area/concern. Each bullet should be concise but descriptive enough to understand without reading the code.>

## Manual Testing Areas

<A bulleted list of areas that manual testers should focus on. For each area:>
- <What to test — be specific about scenarios, user flows, or edge cases>
- <Why it matters — what could go wrong if this area has a defect>

<Think about:>
- <Happy path scenarios for new/changed functionality>
- <Edge cases and boundary conditions>
- <Regression risks — existing functionality that could be affected>
- <Integration points with other systems or modules>
- <Configuration or environment-specific behaviour>

## Risk Rating

**Rating: <Low | Medium | High>**

<One or two sentences justifying the rating. Consider:>
- <Scope of changes (how many files, how central the code is)>
- <Complexity of the logic changed>
- <Whether it touches critical paths (auth, payments, data integrity)>
- <Presence or absence of test coverage>
- <Reversibility — how easy it is to roll back>
```

### Rules
- Be factual — describe what the code actually does, not what you assume it does
- Do not pad or inflate sections. If the PR is simple, the description should be short.
- The manual testing section should be actionable — testers should be able to follow it without reading the code
- Risk rating must be honest. A small, well-tested change is Low risk. Don't inflate to appear thorough.
PROMPT_EOF
)

FULL_PROMPT="${PROMPT_CONTEXT}
${PROMPT_BODY}"

if ! run_codex "$FULL_PROMPT"; then
  echo "ERROR: PR description generation failed — codex exited with a non-zero status." >&2
  echo "  See log: ${LOG_FILE}" >&2
  exit 1
fi

if [ ! -f "$OUTPUT_FILE" ]; then
  echo "ERROR: PR description generation failed — ${OUTPUT_FILE} was not created." >&2
  echo "  Codex ran but did not write the expected file." >&2
  echo "  See log: ${LOG_FILE}" >&2
  exit 1
fi
echo ""

# ══════════════════════════════════════════════════════════════════
# Done
# ══════════════════════════════════════════════════════════════════
trap - EXIT
echo "── PR Description Complete ──────────────────────────────"
echo "  Output file    : ${OUTPUT_FILE}"
echo "────────────────────────────────────────────────────────────"
echo ""
if command -v glow >/dev/null 2>&1; then
  glow "$OUTPUT_FILE"
elif command -v bat >/dev/null 2>&1; then
  bat --language md --style plain --paging never "$OUTPUT_FILE"
else
  cat "$OUTPUT_FILE"
fi
