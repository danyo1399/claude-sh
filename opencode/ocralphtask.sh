#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# ocralphtask.sh
# RALPH Task Pipeline (OpenCode edition):
#   A multi-step Recursive Agentic Loop where a planner agent decides
#   the next task and a builder agent implements it. Tasks are tracked
#   as files moving through backlog/ -> in-progress/ -> done/. The
#   loop exits when the planner emits RALPH_DONE_<SUFFIX>, indicating
#   the overall project goal has been achieved.
#
# Per iteration:
#   1. (planner)  If backlog/ and in-progress/ are both empty, ask
#                 OpenCode what the next task should be (fresh session),
#                 or signal RALPH_DONE_<SUFFIX> if the goal is met.
#   2. (create)   Continue the planner session and write the task file
#                 into backlog/ following the provided template.
#   3. (builder)  Fresh OpenCode session: pick up the task (in-progress
#                 or backlog), move it through in-progress/, implement
#                 it, then move to done/. Crashes are retried with
#                 --continue "continue".
# -------------------------------------------------------------------

usage() {
  cat <<EOF
RALPH Task Pipeline (OpenCode) — planner/builder loop with file-system task tracking.

Each iteration plans a single task (if needed) and then builds it. Tasks are
markdown files that move through backlog/ -> in-progress/ -> done/. The loop
exits when the planner determines the overall goal has been achieved.

Usage: ocralphtask.sh [OPTIONS] --goal-file FILE --template-file FILE --guidelines-file FILE

Required:
  --goal-file FILE          Path to file describing the overarching project goal
  --template-file FILE      Path to file containing the task template (markdown)
  --guidelines-file FILE    Path to file containing working guidelines for the builder

Options:
  -h, --help                   Show this help message and exit
  --tasks-dir DIR              Directory holding backlog/, in-progress/, done/
                               (default: <repo-root>/tasks if in a git repo,
                                otherwise ./tasks)
  --model MODEL                OpenCode model to use (e.g. opencode/claude-opus-4-6)
  --opencode-cmd CMD           Path to opencode binary (default: opencode)
  --max-iterations N           Maximum loop iterations (default: 50)
  --max-builder-attempts N     Max attempts per builder step before giving up
                               (default: 4 — 1 initial + 3 continue retries)
  --dry-run                    Plan only: run the planner step, print the next
                               task, and exit. No task file is written and the
                               builder is not invoked. Useful for previewing
                               planner output safely before a real run.
  --debug                      Verbose diagnostics: enable shell tracing
                               (set -x), log the full prompt sent to the agent
                               on every invocation, and force KEEP_WORK_DIR=1
                               so logs survive script exit.

Environment variables:
  OPENCODE_CMD              Path to opencode binary; --opencode-cmd takes precedence
  OPENCODE_MODEL            Model override; --model takes precedence
  KEEP_WORK_DIR             Set to 1 to preserve temp files (logs) on exit

Examples:
  ocralphtask.sh \\
    --goal-file ./goal.md \\
    --template-file ./task-template.md \\
    --guidelines-file ./guidelines.md

  ocralphtask.sh --model opencode/claude-opus-4-6 --tasks-dir ./project-tasks \\
    --max-iterations 100 \\
    --goal-file goal.md --template-file template.md --guidelines-file rules.md
EOF
}

# -- Parse options ────────────────────────────────────────────────
OPENCODE_CMD="${OPENCODE_CMD:-opencode}"
OPENCODE_MODEL="${OPENCODE_MODEL:-}"
MAX_ITERATIONS=50
MAX_BUILDER_ATTEMPTS=4
DRY_RUN=0
DEBUG="${DEBUG:-0}"
GOAL_FILE=""
TEMPLATE_FILE=""
GUIDELINES_FILE=""
TASKS_DIR=""

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
    --max-iterations)
      MAX_ITERATIONS="$2"
      shift 2
      ;;
    --max-builder-attempts)
      MAX_BUILDER_ATTEMPTS="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --debug)
      DEBUG=1
      shift
      ;;
    --goal-file)
      GOAL_FILE="$2"
      shift 2
      ;;
    --template-file)
      TEMPLATE_FILE="$2"
      shift 2
      ;;
    --guidelines-file)
      GUIDELINES_FILE="$2"
      shift 2
      ;;
    --tasks-dir)
      TASKS_DIR="$2"
      shift 2
      ;;
    -*)
      echo "ERROR: unknown option '$1'" >&2
      echo "  Run 'ocralphtask.sh --help' for usage." >&2
      exit 1
      ;;
    *)
      echo "ERROR: unexpected positional argument '$1'" >&2
      echo "  Run 'ocralphtask.sh --help' for usage." >&2
      exit 1
      ;;
  esac
done

# -- Validate required arguments ─────────────────────────────────
require_file() {
  local var_name="$1"
  local flag="$2"
  local val="${!var_name}"
  if [ -z "$val" ]; then
    echo "ERROR: ${flag} is required." >&2
    echo "  Run 'ocralphtask.sh --help' for usage." >&2
    exit 1
  fi
  if [ ! -f "$val" ]; then
    echo "ERROR: ${flag} file not found: ${val}" >&2
    exit 1
  fi
}

require_file GOAL_FILE --goal-file
require_file TEMPLATE_FILE --template-file
require_file GUIDELINES_FILE --guidelines-file

GOAL="$(cat "$GOAL_FILE")"
TEMPLATE="$(cat "$TEMPLATE_FILE")"
GUIDELINES="$(cat "$GUIDELINES_FILE")"

# -- Git detection (optional) ────────────────────────────────────
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || REPO_ROOT=""
CURRENT_BRANCH=""

if [ -n "$REPO_ROOT" ]; then
  CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || CURRENT_BRANCH=""
  if [ "$CURRENT_BRANCH" = "HEAD" ]; then
    CURRENT_BRANCH="detached at $(git rev-parse --short HEAD)"
    echo "WARNING: detached HEAD state. Using: ${CURRENT_BRANCH}" >&2
  fi
fi

# -- Resolve tasks directory ─────────────────────────────────────
if [ -z "$TASKS_DIR" ]; then
  if [ -n "$REPO_ROOT" ]; then
    TASKS_DIR="${REPO_ROOT}/tasks"
  else
    TASKS_DIR="$(pwd)/tasks"
  fi
fi

case "$TASKS_DIR" in
  /*) ;;
  *) TASKS_DIR="$(pwd)/${TASKS_DIR}" ;;
esac

mkdir -p "${TASKS_DIR}/backlog" "${TASKS_DIR}/in-progress" "${TASKS_DIR}/done"

# -- Generate unique done suffix ─────────────────────────────────
RALPH_SUFFIX="$(LC_ALL=C tr -dc 'A-Z0-9' < /dev/urandom | head -c 12 || true)"
RALPH_DONE_MARKER="RALPH_DONE_${RALPH_SUFFIX}"

# -- Working directory ───────────────────────────────────────────
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
WORK_DIR="${TMPDIR:-/tmp}"
WORK_DIR="${WORK_DIR%/}/ocralphtask-${RUN_ID}"
mkdir -p "$WORK_DIR"

cleanup() {
  if [ "${KEEP_WORK_DIR:-0}" != "1" ] && [ -d "${WORK_DIR:-}" ]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

# -- Apply debug mode effects ────────────────────────────────────
if [ "$DEBUG" = "1" ]; then
  KEEP_WORK_DIR=1
  set -x
fi

LOG_FILE="${WORK_DIR}/opencode.log"

# -- run_opencode helper ─────────────────────────────────────────
# run_opencode PROMPT STDOUT_FILE [--continue]
#   Runs opencode run (or --continue to resume last session),
#   tees stdout to LOG_FILE and STDOUT_FILE,
#   captures stderr, and reports diagnostics on failure.
run_opencode() {
  local prompt="$1"
  local stdout_file="$2"
  local continue_flag="${3:-}"
  local exit_code=0
  local stderr_file="${WORK_DIR}/opencode-stderr.tmp"

  local model_args=()
  if [ -n "$OPENCODE_MODEL" ]; then
    model_args=(--model "$OPENCODE_MODEL")
  fi

  local cmd_args=()
  if [ "$continue_flag" = "--continue" ]; then
    cmd_args=(run "$prompt" --continue)
  else
    cmd_args=(run "$prompt")
  fi

  if [ "$DEBUG" = "1" ]; then
    {
      echo ""
      echo "── prompt sent to opencode (continue=${continue_flag:-no}) ──"
      printf '%s\n' "$prompt"
      echo "── end prompt ──"
      echo ""
    } | tee -a "$LOG_FILE" >&2
  fi

  "$OPENCODE_CMD" "${cmd_args[@]}" ${model_args[@]+"${model_args[@]}"} --dangerously-skip-permissions \
    < /dev/null 2>"$stderr_file" | tee -a "$LOG_FILE" | tee "$stdout_file" || exit_code=$?

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

# -- Helpers ─────────────────────────────────────────────────────
count_files() {
  find "$1" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' '
}

# -- Banner ──────────────────────────────────────────────────────
echo "── RALPH Task Pipeline (OpenCode) ────────────────────────────"
if [ -n "$REPO_ROOT" ]; then
  echo "  Repo root            : ${REPO_ROOT}"
  echo "  Current branch       : ${CURRENT_BRANCH}"
fi
echo "  Tasks dir            : ${TASKS_DIR}"
echo "  Goal file            : ${GOAL_FILE}"
echo "  Template file        : ${TEMPLATE_FILE}"
echo "  Guidelines file      : ${GUIDELINES_FILE}"
echo "  Max iterations       : ${MAX_ITERATIONS}"
echo "  Max builder attempts : ${MAX_BUILDER_ATTEMPTS}"
echo "  Dry run              : ${DRY_RUN}"
echo "  Debug                : ${DEBUG}"
echo "  Done marker          : ${RALPH_DONE_MARKER}"
echo "  OpenCode cmd         : ${OPENCODE_CMD}"
echo "  Model                : ${OPENCODE_MODEL:-<default>}"
echo "  Working dir          : ${WORK_DIR}"
echo "  Log file             : ${LOG_FILE}"
echo "──────────────────────────────────────────────────────────────"
echo ""

# -- Background context (shared by all fresh-session prompts) ────
BACKGROUND_CONTEXT=$(cat <<EOF
BACKGROUND CONTEXT:

You are participating in a multi-step task pipeline. Each iteration of
the pipeline plans a single task and then builds it. Tasks are tracked
as markdown files that move through three folders:

  - ${TASKS_DIR}/backlog       (tasks waiting to be built; max 1 at a time)
  - ${TASKS_DIR}/in-progress   (the task currently being built)
  - ${TASKS_DIR}/done          (completed tasks)

OVERALL PROJECT GOAL:
${GOAL}

WORKING GUIDELINES (always follow these):
${GUIDELINES}

TASK TEMPLATE (use this exact structure when writing a new task file):
${TEMPLATE}

Task files are markdown (.md). Use a 3-digit zero-padded sequence prefix
in filenames (e.g. 001-add-login-form.md). Look at existing files in
backlog/, in-progress/, and done/ to determine the next sequence number.
EOF
)

# -- Loop ────────────────────────────────────────────────────────
ITERATION=0
TOTAL_ELAPSED=0
DONE=0

while [ "$ITERATION" -lt "$MAX_ITERATIONS" ]; do
  ITERATION=$((ITERATION + 1))
  ITER_START="$(date +%s)"

  echo "── Iteration ${ITERATION}/${MAX_ITERATIONS} ──────────────────────────────────"

  BACKLOG_COUNT=$(count_files "${TASKS_DIR}/backlog")
  INPROG_COUNT=$(count_files "${TASKS_DIR}/in-progress")
  DONE_COUNT=$(count_files "${TASKS_DIR}/done")

  echo "  State: backlog=${BACKLOG_COUNT}  in-progress=${INPROG_COUNT}  done=${DONE_COUNT}"

  if [ "$BACKLOG_COUNT" = "0" ] && [ "$INPROG_COUNT" = "0" ]; then
    # ── Step A: Planner (fresh session) ──
    echo "  Step A: Planner (no active task — deciding next task)"
    PLAN_OUTPUT="${WORK_DIR}/iter-${ITERATION}-plan.md"

    PLANNER_PROMPT="${BACKGROUND_CONTEXT}

YOU ARE THE TASK PLANNER.

First, read the current state of ${TASKS_DIR} (backlog/, in-progress/, done/)
to understand what has been planned, started, and completed so far.

Then decide what the SINGLE next task should be in service of the overall
goal. Describe it in 2-4 sentences (what it accomplishes and why). Do NOT
write the task file yet — that happens in the next step.

If, after reviewing the existing tasks, you determine that the overall
goal has been fully achieved and no further tasks are required, end your
response with the marker on its own line:

${RALPH_DONE_MARKER}

Otherwise, end with a brief description of the next task (no marker)."

    if ! run_opencode "$PLANNER_PROMPT" "$PLAN_OUTPUT"; then
      echo "ERROR: Iteration ${ITERATION} — planner step failed (non-zero exit)." >&2
      echo "  See log: ${LOG_FILE}" >&2
      exit 1
    fi

    if [ ! -s "$PLAN_OUTPUT" ]; then
      echo "ERROR: Iteration ${ITERATION} — planner produced no output." >&2
      echo "  See log: ${LOG_FILE}" >&2
      exit 1
    fi

    if grep -qF "$RALPH_DONE_MARKER" "$PLAN_OUTPUT"; then
      echo "  Planner: DONE marker found — overall goal achieved."
      DONE=1
      break
    fi

    if [ "$DRY_RUN" = "1" ]; then
      echo "  Dry run: planner described the next task above. Skipping create + builder."
      break
    fi

    # ── Step B: Create task file (continue planner session) ──
    echo "  Step B: Create task file (continuing planner session)"
    CREATE_OUTPUT="${WORK_DIR}/iter-${ITERATION}-create.md"

    CREATE_PROMPT="Now create the task file for the task you just described.

Write it to ${TASKS_DIR}/backlog/ as a single markdown (.md) file
following the task template from the background context. Use a
descriptive filename with a 3-digit sortable prefix (e.g.
NNN-short-name.md), looking at existing files in backlog/, in-progress/,
and done/ to determine the next sequence number.

Create exactly ONE file in ${TASKS_DIR}/backlog/. After writing it,
confirm the absolute path of the file you created."

    if ! run_opencode "$CREATE_PROMPT" "$CREATE_OUTPUT" --continue; then
      echo "ERROR: Iteration ${ITERATION} — create-task step failed (non-zero exit)." >&2
      echo "  See log: ${LOG_FILE}" >&2
      exit 1
    fi

    NEW_BACKLOG_COUNT=$(count_files "${TASKS_DIR}/backlog")
    if [ "$NEW_BACKLOG_COUNT" = "0" ]; then
      echo "ERROR: Iteration ${ITERATION} — create step did not place a task file in ${TASKS_DIR}/backlog/." >&2
      echo "  See log: ${LOG_FILE}" >&2
      exit 1
    fi
    if [ "$NEW_BACKLOG_COUNT" -gt 1 ]; then
      echo "  WARNING: backlog now contains ${NEW_BACKLOG_COUNT} files; expected exactly 1." >&2
    fi
  else
    echo "  Step A/B: SKIPPED (active task already present)"
    if [ "$DRY_RUN" = "1" ]; then
      echo "  Dry run: skipping builder (active task left untouched)."
      break
    fi
  fi

  # ── Step C: Builder (fresh session, with --continue retry on crash) ──
  echo "  Step C: Builder"
  BUILD_OUTPUT="${WORK_DIR}/iter-${ITERATION}-build.md"

  BUILDER_PROMPT="${BACKGROUND_CONTEXT}

YOU ARE THE TASK BUILDER.

Locate the active task:

  1. First check ${TASKS_DIR}/in-progress/ — if a task file is already
     there, a previous attempt did not finish; pick it up and complete it.
  2. Otherwise, take the (single) task from ${TASKS_DIR}/backlog/ and
     move it to ${TASKS_DIR}/in-progress/ before starting work. If
     several files exist in backlog/, pick the one with the lowest
     sequence-number prefix.

Then:

  3. Read the task file and implement the task following the working
     guidelines from the background context.
  4. Verify the work is complete and correct.
  5. When the task is fully implemented and verified, move the task file
     from ${TASKS_DIR}/in-progress/ to ${TASKS_DIR}/done/.

Do NOT move the task to done/ unless the work is genuinely complete and
verified. ${TASKS_DIR}/in-progress/ should be empty when you finish."

  ATTEMPT=1
  BUILDER_OK=0
  while [ "$ATTEMPT" -le "$MAX_BUILDER_ATTEMPTS" ]; do
    if [ "$ATTEMPT" = "1" ]; then
      echo "  Builder attempt ${ATTEMPT}/${MAX_BUILDER_ATTEMPTS} (fresh session)"
      if run_opencode "$BUILDER_PROMPT" "$BUILD_OUTPUT"; then
        BUILDER_OK=1
        break
      fi
    else
      echo "  Builder crashed; retrying with --continue (attempt ${ATTEMPT}/${MAX_BUILDER_ATTEMPTS})"
      if run_opencode "continue" "$BUILD_OUTPUT" --continue; then
        BUILDER_OK=1
        break
      fi
    fi
    ATTEMPT=$((ATTEMPT + 1))
  done

  if [ "$BUILDER_OK" != "1" ]; then
    echo "ERROR: Iteration ${ITERATION} — builder failed after ${MAX_BUILDER_ATTEMPTS} attempts." >&2
    echo "  See log: ${LOG_FILE}" >&2
    exit 1
  fi

  ITER_END="$(date +%s)"
  ITER_DURATION=$((ITER_END - ITER_START))
  TOTAL_ELAPSED=$((TOTAL_ELAPSED + ITER_DURATION))

  POST_BACKLOG=$(count_files "${TASKS_DIR}/backlog")
  POST_INPROG=$(count_files "${TASKS_DIR}/in-progress")
  POST_DONE=$(count_files "${TASKS_DIR}/done")

  echo ""
  echo "  --- Iteration ${ITERATION} Stats ---"
  echo "  Duration       : ${ITER_DURATION}s"
  echo "  Total elapsed  : ${TOTAL_ELAPSED}s"
  echo "  State after    : backlog=${POST_BACKLOG}  in-progress=${POST_INPROG}  done=${POST_DONE}"
  echo ""
done

# -- Completion ──────────────────────────────────────────────────
if [ "$DONE" != "1" ] && [ "$ITERATION" -ge "$MAX_ITERATIONS" ]; then
  echo "WARNING: reached max iterations (${MAX_ITERATIONS}) without planner signalling DONE." >&2
fi

trap - EXIT

FINAL_BACKLOG=$(count_files "${TASKS_DIR}/backlog")
FINAL_INPROG=$(count_files "${TASKS_DIR}/in-progress")
FINAL_DONE=$(count_files "${TASKS_DIR}/done")

if [ "$DRY_RUN" = "1" ]; then
  echo "── RALPH Task Pipeline Dry Run Complete (OpenCode) ───────────"
else
  echo "── RALPH Task Pipeline Complete (OpenCode) ───────────────────"
fi
echo "  Iterations           : ${ITERATION}"
echo "  Total time           : ${TOTAL_ELAPSED}s"
echo "  Tasks in backlog     : ${FINAL_BACKLOG}"
echo "  Tasks in-progress    : ${FINAL_INPROG}"
echo "  Tasks done           : ${FINAL_DONE}"
echo "  Tasks dir            : ${TASKS_DIR}"
echo "  Working dir          : ${WORK_DIR}"
echo "  Log file             : ${LOG_FILE}"
echo "──────────────────────────────────────────────────────────────"

if [ "$FINAL_DONE" -gt 0 ]; then
  echo ""
  echo "Completed tasks:"
  (cd "${TASKS_DIR}/done" && ls -1 2>/dev/null | sort | sed 's/^/  - /')
fi
