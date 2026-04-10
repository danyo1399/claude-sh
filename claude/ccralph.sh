#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# ccralph.sh
# RALPH (Recursive Agentic Loop Pipeline Harness):
#   Repeatedly invokes Claude with a user prompt until the AI
#   determines there is nothing left to do, signalled by emitting
#   a unique done marker (RALPH_DONE_<SUFFIX>).
# -------------------------------------------------------------------

usage() {
  cat <<EOF
RALPH — Recursive Agentic Loop Pipeline Harness.

Repeatedly invokes Claude with a user prompt in a loop. Each iteration
is a fresh Claude session. The loop exits when Claude includes the
marker text RALPH_DONE_<SUFFIX> in its response, indicating it found
nothing left to do.

Usage: ccralph.sh [OPTIONS] -- PROMPT
       ccralph.sh [OPTIONS] --prompt-file FILE

Arguments:
  PROMPT               The prompt to send to Claude on each iteration.
                       Everything after '--' is treated as the prompt.
                       The script automatically appends done-marker
                       instructions to the prompt.

Options:
  -h, --help           Show this help message and exit
  --model MODEL        Claude model to use (e.g. claude-opus-4-6)
  --claude-cmd CMD     Path to claude binary (default: claude)
  --max-iterations N   Maximum number of iterations before aborting (default: 50)
  --prompt-file FILE   Read the prompt from a file instead of the command line

Environment variables:
  CLAUDE_CMD           Path to claude binary (default: claude); --claude-cmd takes precedence
  CLAUDE_MODEL         Model override (e.g. claude-opus-4-6); --model flag takes precedence
  KEEP_WORK_DIR        Set to 1 to preserve temp files on failure

Examples:
  ccralph.sh -- "Review all TODO comments in this repo and fix them one at a time"
  ccralph.sh --model claude-sonnet-4-20250514 -- "Find and fix lint warnings in src/"
  ccralph.sh --max-iterations 10 -- "Refactor functions longer than 50 lines"
  ccralph.sh --prompt-file my-task.md
EOF
}

# -- Parse options ────────────────────────────────────────────────
CLAUDE_CMD="${CLAUDE_CMD:-claude}"
CLAUDE_MODEL="${CLAUDE_MODEL:-}"
MAX_ITERATIONS=50
USER_PROMPT=""
PROMPT_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --model)
      CLAUDE_MODEL="$2"
      shift 2
      ;;
    --claude-cmd)
      CLAUDE_CMD="$2"
      shift 2
      ;;
    --max-iterations)
      MAX_ITERATIONS="$2"
      shift 2
      ;;
    --prompt-file)
      PROMPT_FILE="$2"
      shift 2
      ;;
    --)
      shift
      USER_PROMPT="$*"
      break
      ;;
    -*)
      echo "ERROR: unknown option '$1'" >&2
      echo "  Run 'ccralph.sh --help' for usage." >&2
      exit 1
      ;;
    *)
      USER_PROMPT="$*"
      break
      ;;
  esac
done

if [ -n "$PROMPT_FILE" ] && [ -n "$USER_PROMPT" ]; then
  echo "ERROR: cannot use both --prompt-file and a command-line prompt." >&2
  exit 1
fi

if [ -n "$PROMPT_FILE" ]; then
  if [ ! -f "$PROMPT_FILE" ]; then
    echo "ERROR: prompt file not found: ${PROMPT_FILE}" >&2
    exit 1
  fi
  USER_PROMPT="$(cat "$PROMPT_FILE")"
fi

if [ -z "$USER_PROMPT" ]; then
  echo "ERROR: no prompt provided." >&2
  echo "  Run 'ccralph.sh --help' for usage." >&2
  exit 1
fi

# -- Git validation ──────────────────────────────────────────────
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

# -- Generate unique done suffix ─────────────────────────────────
RALPH_SUFFIX="$(LC_ALL=C tr -dc 'A-Z0-9' < /dev/urandom | head -c 12 || true)"
RALPH_DONE_MARKER="RALPH_DONE_${RALPH_SUFFIX}"

# -- Working directory ───────────────────────────────────────────
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
WORK_DIR="${TMPDIR:-/tmp}"
WORK_DIR="${WORK_DIR%/}/ccralph-${RUN_ID}"
mkdir -p "$WORK_DIR"

cleanup() {
  if [ "${KEEP_WORK_DIR:-0}" != "1" ] && [ -d "${WORK_DIR:-}" ]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

LOG_FILE="${WORK_DIR}/claude.log"

# -- run_claude helper ───────────────────────────────────────────
# run_claude PROMPT STDOUT_FILE [--continue]
#   Runs claude -p (or --continue to resume last session),
#   tees stdout to LOG_FILE and STDOUT_FILE,
#   captures stderr, and reports diagnostics on failure.
run_claude() {
  local prompt="$1"
  local stdout_file="$2"
  local continue_flag="${3:-}"
  local exit_code=0
  local stderr_file="${WORK_DIR}/claude-stderr.tmp"

  local model_args=()
  if [ -n "$CLAUDE_MODEL" ]; then
    model_args=(--model "$CLAUDE_MODEL")
  fi

  local cmd_args=()
  if [ "$continue_flag" = "--continue" ]; then
    cmd_args=(-p "$prompt" --continue)
  else
    cmd_args=(-p "$prompt")
  fi

  "$CLAUDE_CMD" "${cmd_args[@]}" ${model_args[@]+"${model_args[@]}"} --dangerously-skip-permissions \
    < /dev/null 2>"$stderr_file" | tee -a "$LOG_FILE" > "$stdout_file" || exit_code=$?

  if [ -s "$stderr_file" ]; then
    echo "" >> "$LOG_FILE"
    echo "── stderr ──" >> "$LOG_FILE"
    cat "$stderr_file" >> "$LOG_FILE"
    echo "  Claude stderr:" >&2
    cat "$stderr_file" >&2
  fi
  rm -f "$stderr_file"

  return "$exit_code"
}

# -- Banner ──────────────────────────────────────────────────────
RALPH_LOOP_MARKER="RALPH_LOOP_${RALPH_SUFFIX}"

echo "── RALPH Pipeline ─────────────────────────────────────────"
echo "  Repo root      : ${REPO_ROOT}"
echo "  Current branch : ${CURRENT_BRANCH}"
echo "  Max iterations : ${MAX_ITERATIONS}"
echo "  Done marker    : ${RALPH_DONE_MARKER}"
echo "  Loop marker    : ${RALPH_LOOP_MARKER}"
echo "  Claude cmd     : ${CLAUDE_CMD}"
echo "  Model          : ${CLAUDE_MODEL:-<default>}"
echo "  Working dir    : ${WORK_DIR}"
echo "  Log file       : ${LOG_FILE}"
echo "  Prompt         : ${USER_PROMPT}"
echo "────────────────────────────────────────────────────────────"
echo ""

# -- Build prompt ────────────────────────────────────────────────
PROMPT_CONTEXT="CONTEXT:
- Repository root: ${REPO_ROOT}
- Current branch: ${CURRENT_BRANCH}"

RALPH_INSTRUCTIONS="

IMPORTANT COMPLETION PROTOCOL:
You MUST end every response with exactly one of the following markers:

1. ${RALPH_LOOP_MARKER}
   Include this marker at the very end of your response when you successfully
   performed work in this iteration. A new iteration will start with a fresh
   session so you can continue or verify.

2. ${RALPH_DONE_MARKER}
   Include this marker at the very end of your response when you examine the
   codebase and determine there is nothing left to do. Only use this when you
   are confident there is genuinely no remaining work.

You MUST include exactly one of these two markers at the end of every response."

FULL_PROMPT="${PROMPT_CONTEXT}

${USER_PROMPT}${RALPH_INSTRUCTIONS}"

# -- Loop ────────────────────────────────────────────────────────
ITERATION=0
TOTAL_ELAPSED=0
CONSECUTIVE_CONTINUES=0
MAX_CONTINUES=3

while [ "$ITERATION" -lt "$MAX_ITERATIONS" ]; do
  ITERATION=$((ITERATION + 1))
  ITER_OUTPUT="${WORK_DIR}/iteration-${ITERATION}.md"
  ITER_START="$(date +%s)"

  echo "── Iteration ${ITERATION}/${MAX_ITERATIONS} ──────────────────────────────────"

  if [ "$CONSECUTIVE_CONTINUES" -gt 0 ]; then
    echo "  Mode           : CONTINUE (resuming session, attempt ${CONSECUTIVE_CONTINUES}/${MAX_CONTINUES})"
  fi
  echo ""

  if [ "$CONSECUTIVE_CONTINUES" -gt 0 ]; then
    # Resume previous session with "continue"
    if ! run_claude "continue" "$ITER_OUTPUT" --continue; then
      echo "ERROR: Iteration ${ITERATION} failed — claude exited with a non-zero status." >&2
      echo "  See log: ${LOG_FILE}" >&2
      exit 1
    fi
  else
    # Fresh session with full prompt
    if ! run_claude "$FULL_PROMPT" "$ITER_OUTPUT"; then
      echo "ERROR: Iteration ${ITERATION} failed — claude exited with a non-zero status." >&2
      echo "  See log: ${LOG_FILE}" >&2
      exit 1
    fi
  fi

  if [ ! -s "$ITER_OUTPUT" ]; then
    echo "ERROR: Iteration ${ITERATION} failed — ${ITER_OUTPUT} was not created or is empty." >&2
    echo "  Claude ran but did not produce output." >&2
    echo "  See log: ${LOG_FILE}" >&2
    exit 1
  fi

  ITER_END="$(date +%s)"
  ITER_DURATION=$((ITER_END - ITER_START))
  TOTAL_ELAPSED=$((TOTAL_ELAPSED + ITER_DURATION))

  echo ""
  echo "  --- Iteration ${ITERATION} Stats ---"
  echo "  Duration       : ${ITER_DURATION}s"
  echo "  Total elapsed  : ${TOTAL_ELAPSED}s"
  echo "  Output file    : ${ITER_OUTPUT}"

  # Check for markers
  if grep -qF "$RALPH_DONE_MARKER" "$ITER_OUTPUT" 2>/dev/null; then
    echo "  Status         : DONE (done marker found)"
    echo ""
    break
  elif grep -qF "$RALPH_LOOP_MARKER" "$ITER_OUTPUT" 2>/dev/null; then
    echo "  Status         : LOOP (loop marker found — starting next iteration)"
    echo ""
    CONSECUTIVE_CONTINUES=0
  else
    CONSECUTIVE_CONTINUES=$((CONSECUTIVE_CONTINUES + 1))
    echo "  Status         : NO MARKER (resuming session with continue, ${CONSECUTIVE_CONTINUES}/${MAX_CONTINUES})"
    echo ""
    if [ "$CONSECUTIVE_CONTINUES" -ge "$MAX_CONTINUES" ]; then
      echo "ERROR: ${MAX_CONTINUES} consecutive iterations without a marker. Aborting." >&2
      echo "  See log: ${LOG_FILE}" >&2
      exit 1
    fi
  fi
done

# -- Completion ──────────────────────────────────────────────────
if [ "$ITERATION" -ge "$MAX_ITERATIONS" ] && ! grep -qF "$RALPH_DONE_MARKER" "${WORK_DIR}/iteration-${ITERATION}.md" 2>/dev/null; then
  echo "WARNING: reached max iterations (${MAX_ITERATIONS}) without done marker." >&2
fi

trap - EXIT

echo "── RALPH Complete ─────────────────────────────────────────"
echo "  Iterations     : ${ITERATION}"
echo "  Total time     : ${TOTAL_ELAPSED}s"
echo "  Working dir    : ${WORK_DIR}"
echo "  Log file       : ${LOG_FILE}"
echo "────────────────────────────────────────────────────────────"
echo ""

FINAL_OUTPUT="${WORK_DIR}/iteration-${ITERATION}.md"
if [ -f "$FINAL_OUTPUT" ]; then
  if command -v glow >/dev/null 2>&1; then
    glow "$FINAL_OUTPUT"
  elif command -v bat >/dev/null 2>&1; then
    bat --language md --style plain --paging never "$FINAL_OUTPUT"
  else
    cat "$FINAL_OUTPUT"
  fi
fi
