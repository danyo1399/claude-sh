#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# cccodereview.sh
# Two-step AI code review pipeline:
#   1. Draft   — code review draft      → PR_CODE_REVIEW_DRAFT.md
#   2. Audit   — validate & finalise    → stdout
# -------------------------------------------------------------------

usage() {
  cat <<EOF
Two-step AI code review pipeline that drafts a review of your branch
changes and then audits the draft to produce a validated final review.

Usage: cccodereview.sh [OPTIONS] [BASE_BRANCH]

Arguments:
  BASE_BRANCH          Branch to diff against (default: main).
                       Ignored when --staged, --unstaged, or --pending is used.

Options:
  -h, --help           Show this help message and exit
  --model MODEL        Claude model to use (default: claude-opus-4-6)
  --claude-cmd CMD     Path to claude binary (default: claude)
  --staged             Review only staged (indexed) changes
  --unstaged           Review only unstaged working-tree changes
  --pending            Review all uncommitted changes (staged + unstaged)

Environment variables:
  CLAUDE_CMD           Path to claude binary (default: claude)
  CLAUDE_MODEL         Model override; --model flag takes precedence
  KEEP_WORK_DIR        Set to 1 to preserve temp files on failure

Examples:
  cccodereview.sh                        # review branch vs main
  cccodereview.sh develop                # review branch vs develop
  cccodereview.sh --staged               # review staged changes only
  cccodereview.sh --pending              # review all uncommitted changes
  cccodereview.sh --model claude-sonnet-4-20250514 feature/main
EOF
}

# ── Parse options ────────────────────────────────────────────────
CLAUDE_CMD="${CLAUDE_CMD:-claude}"
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-opus-4-6}"
BASE_BRANCH=""
REVIEW_MODE="branch"

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
    --staged)
      REVIEW_MODE="staged"
      shift
      ;;
    --unstaged)
      REVIEW_MODE="unstaged"
      shift
      ;;
    --pending)
      REVIEW_MODE="pending"
      shift
      ;;
    -*)
      echo "ERROR: unknown option '$1'" >&2
      echo "  Run 'cccodereview.sh --help' for usage." >&2
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
  echo "ERROR: no commits on current branch. Cannot run code review." >&2
  exit 1
}

if [ "$CURRENT_BRANCH" = "HEAD" ]; then
  CURRENT_BRANCH="detached at $(git rev-parse --short HEAD)"
  echo "WARNING: detached HEAD state. Using: ${CURRENT_BRANCH}" >&2
fi

# ── Review mode setup ────────────────────────────────────────────
case "$REVIEW_MODE" in
  branch)
    if ! git rev-parse --verify "${BASE_BRANCH}" >/dev/null 2>&1; then
      echo "ERROR: base branch '${BASE_BRANCH}' does not exist." >&2
      exit 1
    fi
    REVIEW_LABEL="branch vs ${BASE_BRANCH}"
    GIT_DIFF_INSTRUCTION="Use git to examine all changes in this branch (committed, staged, and unstaged) compared to the base branch. Run git diff ${BASE_BRANCH}...HEAD, git log, and any other git commands you need."
    ;;
  staged)
    if git diff --cached --quiet; then
      echo "ERROR: no staged changes to review." >&2
      exit 1
    fi
    REVIEW_LABEL="staged changes"
    GIT_DIFF_INSTRUCTION="Use git to examine only the staged (indexed) changes. Run git diff --cached to see the changes. Do NOT review unstaged or committed branch changes."
    ;;
  unstaged)
    if git diff --quiet; then
      echo "ERROR: no unstaged changes to review." >&2
      exit 1
    fi
    REVIEW_LABEL="unstaged changes"
    GIT_DIFF_INSTRUCTION="Use git to examine only the unstaged working-tree changes. Run git diff to see the changes. Do NOT review staged or committed branch changes."
    ;;
  pending)
    if git diff --cached --quiet && git diff --quiet; then
      echo "ERROR: no uncommitted changes to review." >&2
      exit 1
    fi
    REVIEW_LABEL="pending changes (staged + unstaged)"
    GIT_DIFF_INSTRUCTION="Use git to examine all uncommitted changes (both staged and unstaged). Run git diff HEAD to see the combined changes. Do NOT review committed branch changes."
    ;;
esac

# Unique working directory outside the repo
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
WORK_DIR="${TMPDIR:-/tmp}/code-review-${RUN_ID}"
mkdir -p "$WORK_DIR"

# Clean up working directory on failure or interrupt.
# On success the trap is disabled so output files persist.
# Set KEEP_WORK_DIR=1 to preserve files even on failure.
cleanup() {
  if [ "${KEEP_WORK_DIR:-0}" != "1" ] && [ -d "${WORK_DIR:-}" ]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

DRAFT_FILE="${WORK_DIR}/PR_CODE_REVIEW_DRAFT.md"
LOG_FILE="${WORK_DIR}/claude.log"

# run_claude PROMPT [STDOUT_FILE]
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

echo "── Code Review Pipeline ───────────────────────────────────"
echo "  Repo root      : ${REPO_ROOT}"
echo "  Current branch : ${CURRENT_BRANCH}"
echo "  Review scope   : ${REVIEW_LABEL}"
echo "  Claude cmd     : ${CLAUDE_CMD}"
echo "  Model          : ${CLAUDE_MODEL}"
echo "  Working dir    : ${WORK_DIR}"
echo "  Log file       : ${LOG_FILE}"
echo "──────────────────────────────────────────────────────────"
echo ""

# ══════════════════════════════════════════════════════════════════
# STEP 1: Draft Code Review
# ══════════════════════════════════════════════════════════════════
echo "── Step 1/2: Draft Code Review ──────────────────────────"
echo ""

PROMPT_CONTEXT="CONTEXT:
- Repository root: ${REPO_ROOT}
- Current branch: ${CURRENT_BRANCH}
- Review scope: ${REVIEW_LABEL}
- Git diff instruction: ${GIT_DIFF_INSTRUCTION}
- Draft output file: ${DRAFT_FILE}"

PROMPT_BODY=$(cat <<'PROMPT_EOF'

You are an expert code reviewer coordinating a thorough, parallelised code review.

INSTRUCTIONS:

Follow the git diff instruction in the CONTEXT above to obtain the changes to review. Also run any other git commands you need. Research the codebase in depth to understand the changes — read every relevant file in full, understand the architecture, data flow, and all specificities.

## Review Strategy

Follow these phases in order:

### Phase 1: Analyse & Partition
Analyse the code changes and identify areas that can be reviewed separately. Group changes into logical review areas based on concern (e.g., by feature, module, layer, or file cluster). Each area should be independently reviewable.

### Phase 2: Parallel Agent Reviews
For each area identified in Phase 1, use a subagent to perform a focused code review of that area. Each agent should:
- Receive the relevant file paths and a description of the area it is reviewing
- Examine the actual code changes in its area using git diff and file reads
- Apply the review rules and severity classification defined below
- Return its findings in markdown

Launch all area review agents in parallel for efficiency.

### Phase 3: Collate
Collate all agent area code reviews into a single, unified code review covering all areas. Deduplicate any overlapping findings. Ensure consistent severity classification across areas.

Your ONLY deliverable is writing the draft output file listed above. The response must be in markdown.

Make NO assumptions — explore the codebase and verify every assumption made in the code changes. ONLY report issues where you have concrete evidence. Do NOT suggest verification tasks for hypothetical scenarios.

Include file names and line numbers where possible.

## Document Structure

### 1. Pull Request Summary
Write a pull request summary for reviewers FIRST, before the code review findings. Include:
- What the PR does (concise)
- Key changes
- Files affected

### 2. Code Review Findings
- Only report on code defects or code quality issues
- Group defects by severity
- Do not list trivial code quality issues
- There is no need to give positive feedback

### Comment Review Rules
When reviewing code comments, focus on substantive issues only. Do NOT flag:
- Developer initials or attribution in comments (e.g., "CB:", "// John:")
- References to ticket numbers or work items (e.g., "Jira ERST-31197")
- Temporal markers like "Added", "Removed", "Fixed" with context
Attribution and ticket references are valuable context for future maintainers.

Only flag comments that are:
- Factually incorrect
- Misleading about code behavior
- Contradicting the actual implementation
- Completely redundant with obvious code
- Using unclear or ambiguous language

### Severity Classification

Use these definitions strictly. Most PRs should have zero Critical or High severity findings — do not inflate severity to appear thorough. Do NOT include severity justifications in the output.

**Critical** — Security vulnerability exploitable in production (e.g., auth bypass, injection, secret exposure), guaranteed data loss or corruption, or a defect that will cause immediate production failure on deploy with no workaround.

**High** — Will cause a bug, crash, or silently incorrect behavior in production under normal usage *as the code is written today*. There must be a concrete, reproducible failure path — not theoretical.

**Medium** — Creates operational risk under specific but realistic conditions, meaningfully degrades maintainability, or introduces a latent defect that will surface if reasonable assumptions change (e.g., config drift, scaling).

**Low** — Code smell, minor robustness improvement, style inconsistency, speculative future risk, or edge case that requires unlikely conditions to trigger.

**Severity guidelines:**
- A configuration that works correctly today but could break if a dependency or environment changes in the future is Medium at most.
- Leaking non-secret infrastructure details (hostnames, internal naming) is Medium at most.
- "This dependency might change its requirements someday" is Low.
- If an issue only matters when a condition is met, state the condition and factor its likelihood into severity.
PROMPT_EOF
)

PROMPT_DRAFT="${PROMPT_CONTEXT}
${PROMPT_BODY}"

if ! run_claude "$PROMPT_DRAFT"; then
  echo "ERROR: Step 1 failed — claude exited with a non-zero status." >&2
  echo "  See log: ${LOG_FILE}" >&2
  exit 1
fi

if [ ! -f "$DRAFT_FILE" ]; then
  echo "ERROR: Step 1 failed — ${DRAFT_FILE} was not created." >&2
  echo "  Claude ran but did not write the expected file." >&2
  echo "  See log: ${LOG_FILE}" >&2
  exit 1
fi
echo ""
echo "  Step 1 complete: ${DRAFT_FILE}"
echo ""

# ══════════════════════════════════════════════════════════════════
# STEP 2: Audit & Finalise
# ══════════════════════════════════════════════════════════════════
echo "── Step 2/2: Audit & Finalise ───────────────────────────"
echo ""

PROMPT_CONTEXT="CONTEXT:
- Repository root: ${REPO_ROOT}
- Current branch: ${CURRENT_BRANCH}
- Review scope: ${REVIEW_LABEL}
- Git diff instruction: ${GIT_DIFF_INSTRUCTION}
- Draft review file: ${DRAFT_FILE}"

PROMPT_BODY=$(cat <<'PROMPT_EOF'

You are a senior code review auditor. Your job is to:

1. Review a draft AI-generated code review and identify any issues that are false, speculative, or invalid
2. Produce a final, clean code review containing only validated issues

INSTRUCTIONS:

Read the draft code review from the draft review file listed above. Follow the git diff instruction in the CONTEXT above to obtain the changes under review. For each issue raised in the draft, verify it against the actual codebase. Explore the codebase to confirm or refute each finding.

## Phase 1: Audit Each Issue

For each issue in the draft review, evaluate it against these criteria:

### Definitely Invalid - Remove
- **Speculative issues**: The reviewer assumes a bug or problem exists without evidence in the code
- **Phantom code references**: The review mentions code, variables, methods, or files that don't exist in the diff
- **Misread logic**: The reviewer misunderstands what the code actually does
- **False positives**: The code is actually correct but flagged as wrong
- **Hallucinated context**: The reviewer invents business rules, requirements, or architectural constraints not evident from the code
- **Already handled**: The issue is addressed elsewhere in the code but the reviewer missed it

### Likely Invalid - Remove Unless Strong Evidence
- **Severity inflation**: A minor style preference presented as a critical bug
- **Subjective opinions stated as defects**: e.g. "this should use pattern X" when the current approach is perfectly valid
- **Out-of-scope concerns**: Issues unrelated to the changes in this PR
- **Assumed missing context**: The reviewer flags something as wrong that likely has context outside the diff

## Phase 2: Produce Final Review

Respond with the final code review in markdown containing only the validated issues.

### Rules for the Final Review
- Every issue must reference a specific file and line or code snippet from the diff
- No speculative language ("this might cause...", "there could be...") unless clearly flagged as a consideration rather than a defect
- Severity must be proportional — don't elevate style preferences to critical
- If the draft review has zero valid issues, say so. A clean PR is a valid outcome.
- Be concise. One clear sentence per issue is better than a paragraph.
- Do not document changes made during the audit. Do not list removed issues.
- Preserve the pull request summary from the draft review.

Your ONLY deliverable is responding with the final code review. Do NOT write any files.
PROMPT_EOF
)

PROMPT_FINAL="${PROMPT_CONTEXT}
${PROMPT_BODY}"

REVIEW_OUTPUT="${WORK_DIR}/PR_CODE_REVIEW.md"
if ! run_claude "$PROMPT_FINAL" "$REVIEW_OUTPUT"; then
  echo "ERROR: Step 2 failed — claude exited with a non-zero status." >&2
  echo "  See log: ${LOG_FILE}" >&2
  exit 1
fi

if [ ! -s "$REVIEW_OUTPUT" ]; then
  echo "ERROR: Step 2 failed — ${REVIEW_OUTPUT} is empty." >&2
  echo "  See log: ${LOG_FILE}" >&2
  exit 1
fi
echo ""

# ══════════════════════════════════════════════════════════════════
# Done
# ══════════════════════════════════════════════════════════════════
trap - EXIT
echo "── Code Review Complete ─────────────────────────────────"
echo "  Draft review   : ${DRAFT_FILE}"
echo "────────────────────────────────────────────────────────"
echo ""
if command -v glow >/dev/null 2>&1; then
  glow "$REVIEW_OUTPUT"
elif command -v bat >/dev/null 2>&1; then
  bat --language md --style plain --paging never "$REVIEW_OUTPUT"
else
  cat "$REVIEW_OUTPUT"
fi
