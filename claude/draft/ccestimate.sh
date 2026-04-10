#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# estimate.sh
# AI-powered project work estimation pipeline:
#   1. Discovery  — analyse the codebase and requirements → DISCOVERY.md
#   2. Breakdown  — decompose into estimable work items   → BREAKDOWN.md
#   3. Estimate   — size each item and produce report     → ESTIMATE.md
#
# Usage:
#   estimate.sh init [DIR]
#   estimate.sh [OPTIONS] <requirements>
#
# Commands:
#   init [DIR]      Create the estimation project folder structure.
#                   DIR defaults to ./estimation in the current directory.
#
# Options:
#   --model MODEL   Override the Claude model (default: claude-opus-4-6)
#   --file FILE     Read requirements from a file instead of positional arg
#   -h, --help      Show this help message
#
# Examples:
#   estimate.sh init
#   estimate.sh init my-project-estimate
#   estimate.sh "Add user authentication with OAuth2"
#   estimate.sh --file requirements.md
#   estimate.sh --model claude-sonnet-4-6 "Refactor the payment module"
# -------------------------------------------------------------------

# ── Defaults & configuration ──────────────────────────────────────
CLAUDE_CMD="${CLAUDE_CMD:-claude}"
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-opus-4-6}"
REQUIREMENTS=""
REQUIREMENTS_FILE=""

# ── help (check before subcommands so -h always works) ───────────
show_help() {
  sed -n '/^# ---/,/^# ---/p' "$0" | sed '1d;$d' | sed 's/^# \?//'
  exit 0
}
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  show_help
fi

# ── init command ──────────────────────────────────────────────────
if [ "${1:-}" = "init" ]; then
  shift
  if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    show_help
  fi
  INIT_DIR="${1:-./estimation}"

  if [ -d "$INIT_DIR" ]; then
    echo "ERROR: directory already exists: ${INIT_DIR}" >&2
    exit 1
  fi

  mkdir -p \
    "${INIT_DIR}/ai/architecture" \
    "${INIT_DIR}/ai/questions" \
    "${INIT_DIR}/ai/reports" \
    "${INIT_DIR}/ai/requirements" \
    "${INIT_DIR}/ai/tasks" \
    "${INIT_DIR}/user/documents" \
    "${INIT_DIR}/user/reference/documents" \
    "${INIT_DIR}/user/reference/repositories"

  cat > "${INIT_DIR}/ai/architecture/CLAUDE.md" <<'EOF'
AI-generated architecture analysis and design documents for the project being estimated.
EOF
  cat > "${INIT_DIR}/ai/questions/CLAUDE.md" <<'EOF'
AI-generated clarifying questions about requirements, scope, and technical decisions.
EOF
  cat > "${INIT_DIR}/ai/reports/CLAUDE.md" <<'EOF'
AI-generated estimation reports including effort breakdowns and risk assessments.
EOF
  cat > "${INIT_DIR}/ai/requirements/CLAUDE.md" <<'EOF'
AI-refined and expanded requirements derived from user-provided inputs.
EOF
  cat > "${INIT_DIR}/ai/tasks/CLAUDE.md" <<'EOF'
AI-generated work item breakdowns and task decompositions.
EOF
  cat > "${INIT_DIR}/user/documents/CLAUDE.md" <<'EOF'
User-provided documents such as specs, meeting notes, emails, and other project context.
EOF
  cat > "${INIT_DIR}/user/reference/documents/CLAUDE.md" <<'EOF'
External reference documents such as RFCs, API docs, design guides, and technical specs.
EOF
  cat > "${INIT_DIR}/user/reference/repositories/CLAUDE.md" <<'EOF'
Cloned repositories or repo links used as reference for the estimation.
EOF

  git init "$INIT_DIR" >/dev/null 2>&1

  echo "── Estimation project initialised ─────────────────────────"
  echo "  ${INIT_DIR}/"
  echo "  ├── ai/"
  echo "  │   ├── architecture/"
  echo "  │   ├── questions/"
  echo "  │   ├── reports/"
  echo "  │   ├── requirements/"
  echo "  │   └── tasks/"
  echo "  └── user/"
  echo "      ├── documents/"
  echo "      └── reference/"
  echo "          ├── documents/"
  echo "          └── repositories/"
  echo "───────────────────────────────────────────────────────────"
  exit 0
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)    CLAUDE_MODEL="$2"; shift 2 ;;
    --file)     REQUIREMENTS_FILE="$2"; shift 2 ;;
    -h|--help)  show_help ;;
    -*)         echo "Unknown option: $1" >&2; exit 1 ;;
    *)          REQUIREMENTS="$1"; shift ;;
  esac
done

# Resolve requirements from file or argument
if [ -n "$REQUIREMENTS_FILE" ]; then
  if [ ! -f "$REQUIREMENTS_FILE" ]; then
    echo "ERROR: requirements file not found: ${REQUIREMENTS_FILE}" >&2
    exit 1
  fi
  REQUIREMENTS="$(cat "$REQUIREMENTS_FILE")"
fi

if [ -z "$REQUIREMENTS" ]; then
  echo "ERROR: no requirements provided. Pass as argument or use --file." >&2
  echo "  Usage: estimate.sh [OPTIONS] <requirements>" >&2
  echo "  Run estimate.sh --help for details." >&2
  exit 1
fi

# ── Git repository validation ────────────────────────────────────
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

# ── Working directory ─────────────────────────────────────────────
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
WORK_DIR="${TMPDIR:-/tmp}"
WORK_DIR="${WORK_DIR%/}/estimate-${RUN_ID}"
mkdir -p "$WORK_DIR"

cleanup() {
  if [ "${KEEP_WORK_DIR:-0}" != "1" ] && [ -d "${WORK_DIR:-}" ]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

DISCOVERY_FILE="${WORK_DIR}/DISCOVERY.md"
BREAKDOWN_FILE="${WORK_DIR}/BREAKDOWN.md"
ESTIMATE_FILE="${WORK_DIR}/ESTIMATE.md"
LOG_FILE="${WORK_DIR}/claude.log"

# ── run_claude PROMPT [STDOUT_FILE] ──────────────────────────────
#   Runs claude -p, tees stdout to LOG_FILE (and optional STDOUT_FILE),
#   captures stderr, and reports diagnostics on failure.
run_claude() {
  local prompt="$1"
  local stdout_file="${2:-}"
  local exit_code=0
  local stderr_file="${WORK_DIR}/claude-stderr.tmp"

  if [ -n "$stdout_file" ]; then
    $CLAUDE_CMD -p "$prompt" --model "$CLAUDE_MODEL" --dangerously-skip-permissions \
      < /dev/null 2>"$stderr_file" | tee -a "$LOG_FILE" > "$stdout_file" || exit_code=$?
  else
    $CLAUDE_CMD -p "$prompt" --model "$CLAUDE_MODEL" --dangerously-skip-permissions \
      < /dev/null 2>"$stderr_file" | tee -a "$LOG_FILE" || exit_code=$?
  fi

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

# ── Pipeline banner ───────────────────────────────────────────────
echo "── Project Estimation Pipeline ────────────────────────────"
echo "  Repo root      : ${REPO_ROOT}"
echo "  Current branch : ${CURRENT_BRANCH}"
echo "  Claude cmd     : ${CLAUDE_CMD}"
echo "  Model          : ${CLAUDE_MODEL}"
echo "  Working dir    : ${WORK_DIR}"
echo "  Log file       : ${LOG_FILE}"
echo "───────────────────────────────────────────────────────────"
echo ""

# ══════════════════════════════════════════════════════════════════
# STEP 1: Discovery
# ══════════════════════════════════════════════════════════════════
echo "── Step 1/3: Discovery ──────────────────────────────────"
echo ""

PROMPT_CONTEXT="CONTEXT:
- Repository root: ${REPO_ROOT}
- Current branch: ${CURRENT_BRANCH}
- Discovery output file: ${DISCOVERY_FILE}

REQUIREMENTS:
${REQUIREMENTS}"

PROMPT_BODY=$(cat <<'PROMPT_EOF'

You are performing a codebase discovery task to support project estimation.

INSTRUCTIONS:

Analyse the repository to understand its architecture, patterns, and conventions. Focus on areas relevant to the requirements listed above. Read files, explore directories, and build a thorough understanding of the codebase.

Your ONLY deliverable is writing the discovery output file listed above.

Write the following sections:

## Requirements Summary
Restate the requirements in your own words. Identify any ambiguities or assumptions.

## Codebase Overview
Describe the project structure, key technologies, frameworks, and architectural patterns.

## Relevant Areas
List the files, modules, and subsystems that would be affected by or related to the requirements. For each area, briefly describe its purpose and current state.

## Existing Patterns
How similar features are currently implemented. Document naming conventions, folder structure, component patterns, API patterns, and testing patterns relevant to the work.

## Dependencies and Integrations
External libraries, internal shared code, APIs, and services that the work would need to interact with.

## Technical Constraints
Known limitations, compatibility requirements, performance considerations, or other constraints that would affect the work.

## Risks and Unknowns
Areas of uncertainty, potential blockers, or things that need further clarification before work can begin.

Be thorough. Keep exploring until you have a complete picture of what the requirements involve.
PROMPT_EOF
)

PROMPT_DISCOVERY="${PROMPT_CONTEXT}
${PROMPT_BODY}"

if ! run_claude "$PROMPT_DISCOVERY"; then
  echo "ERROR: Step 1 failed — claude exited with a non-zero status." >&2
  echo "  See log: ${LOG_FILE}" >&2
  exit 1
fi

if [ ! -f "$DISCOVERY_FILE" ]; then
  echo "ERROR: Step 1 failed — ${DISCOVERY_FILE} was not created." >&2
  echo "  Claude ran but did not write the expected file." >&2
  echo "  See log: ${LOG_FILE}" >&2
  exit 1
fi
echo ""
echo "  Step 1 complete: ${DISCOVERY_FILE}"
echo ""

# ══════════════════════════════════════════════════════════════════
# STEP 2: Work Breakdown
# ══════════════════════════════════════════════════════════════════
echo "── Step 2/3: Work Breakdown ─────────────────────────────"
echo ""

PROMPT_CONTEXT="CONTEXT:
- Repository root: ${REPO_ROOT}
- Current branch: ${CURRENT_BRANCH}
- Discovery file: ${DISCOVERY_FILE}
- Breakdown output file: ${BREAKDOWN_FILE}

REQUIREMENTS:
${REQUIREMENTS}"

PROMPT_BODY=$(cat <<'PROMPT_EOF'

You are a senior software engineer breaking down project requirements into estimable work items.

INSTRUCTIONS:

Read the discovery file listed above to understand the codebase context. Also explore the codebase yourself to verify and supplement the discovery findings.

Decompose the requirements into discrete, estimable work items. Each item should be small enough to estimate with reasonable confidence.

Your ONLY deliverable is writing the breakdown output file listed above.

Write the following sections:

## Work Items

For each work item, provide:

### WI-{number}: {title}

- **Description**: What needs to be done, in concrete terms
- **Files affected**: List specific files that would be created or modified
- **Dependencies**: Other work items that must be completed first (by WI number)
- **Complexity factors**: What makes this item easy or hard (new vs familiar patterns, integration points, edge cases)
- **Acceptance criteria**: How to verify this item is complete

## Ordering
Suggested implementation order, accounting for dependencies between items.

## Out of Scope
Anything that was considered but excluded, and why.

Keep items granular enough to estimate but not so granular that they become trivial. A good work item represents a coherent unit of work that delivers a verifiable result.
PROMPT_EOF
)

PROMPT_BREAKDOWN="${PROMPT_CONTEXT}
${PROMPT_BODY}"

if ! run_claude "$PROMPT_BREAKDOWN"; then
  echo "ERROR: Step 2 failed — claude exited with a non-zero status." >&2
  echo "  See log: ${LOG_FILE}" >&2
  exit 1
fi

if [ ! -f "$BREAKDOWN_FILE" ]; then
  echo "ERROR: Step 2 failed — ${BREAKDOWN_FILE} was not created." >&2
  echo "  Claude ran but did not write the expected file." >&2
  echo "  See log: ${LOG_FILE}" >&2
  exit 1
fi
echo ""
echo "  Step 2 complete: ${BREAKDOWN_FILE}"
echo ""

# ══════════════════════════════════════════════════════════════════
# STEP 3: Estimate
# ══════════════════════════════════════════════════════════════════
echo "── Step 3/3: Estimate ───────────────────────────────────"
echo ""

PROMPT_CONTEXT="CONTEXT:
- Repository root: ${REPO_ROOT}
- Current branch: ${CURRENT_BRANCH}
- Discovery file: ${DISCOVERY_FILE}
- Breakdown file: ${BREAKDOWN_FILE}
- Estimate output file: ${ESTIMATE_FILE}

REQUIREMENTS:
${REQUIREMENTS}"

PROMPT_BODY=$(cat <<'PROMPT_EOF'

You are a senior software engineer producing effort estimates for a set of work items.

INSTRUCTIONS:

Read the discovery file and breakdown file listed above. Also explore the codebase yourself to verify complexity assessments and check for anything the previous steps may have missed.

For each work item in the breakdown, estimate the effort required. Then produce a summary estimation report.

Your ONLY deliverable is writing the estimate output file listed above.

Write the following sections:

## Estimation Summary

| Work Item | Title | Estimate | Confidence | Risk |
|-----------|-------|----------|------------|------|

Provide a table with:
- **Estimate**: T-shirt size (XS, S, M, L, XL) with approximate hour ranges:
  - XS: < 1 hour
  - S: 1–4 hours
  - M: 4–8 hours (half day to full day)
  - L: 1–3 days
  - XL: 3–5 days
- **Confidence**: High / Medium / Low — how sure you are about the estimate
- **Risk**: High / Medium / Low — likelihood of unexpected complications

## Totals

- **Total estimated effort**: sum of all items as a range (e.g. "3–5 days")
- **Overall confidence**: aggregate assessment
- **Overall risk**: aggregate assessment

## Work Item Details

For each work item, explain:

### WI-{number}: {title}
- **Estimate**: {size} ({hour range})
- **Confidence**: {level}
- **Risk**: {level}
- **Rationale**: Why this estimate — reference specific codebase findings, patterns, complexity factors
- **Risks**: Specific things that could cause this to take longer

## Assumptions
List all assumptions that the estimates depend on. If any assumption is wrong, flag which estimates would change and in what direction.

## Recommendations
Any suggestions for reducing risk, improving confidence, or reordering work to de-risk the project early.

Be honest about uncertainty. A wide range with high confidence is more useful than a narrow range with low confidence. When in doubt, estimate higher rather than lower.
PROMPT_EOF
)

PROMPT_ESTIMATE="${PROMPT_CONTEXT}
${PROMPT_BODY}"

if ! run_claude "$PROMPT_ESTIMATE"; then
  echo "ERROR: Step 3 failed — claude exited with a non-zero status." >&2
  echo "  See log: ${LOG_FILE}" >&2
  exit 1
fi

if [ ! -f "$ESTIMATE_FILE" ]; then
  echo "ERROR: Step 3 failed — ${ESTIMATE_FILE} was not created." >&2
  echo "  Claude ran but did not write the expected file." >&2
  echo "  See log: ${LOG_FILE}" >&2
  exit 1
fi
echo ""

# ══════════════════════════════════════════════════════════════════
# Done
# ══════════════════════════════════════════════════════════════════
trap - EXIT
echo "── Estimation Complete ────────────────────────────────────"
echo "  Discovery      : ${DISCOVERY_FILE}"
echo "  Breakdown      : ${BREAKDOWN_FILE}"
echo "  Estimate       : ${ESTIMATE_FILE}"
echo "───────────────────────────────────────────────────────────"
echo ""
if command -v glow >/dev/null 2>&1; then
  glow "$ESTIMATE_FILE"
elif command -v bat >/dev/null 2>&1; then
  bat --language md --style plain --paging never "$ESTIMATE_FILE"
else
  cat "$ESTIMATE_FILE"
fi
