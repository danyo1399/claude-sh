#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# code-review.sh
# Three-step AI code review pipeline:
#   1. Research — deep codebase analysis → PR_RESEARCH.md
#   2. Draft   — code review draft      → PR_CODE_REVIEW_DRAFT.md
#   3. Audit   — validate & finalise    → stdout
# -------------------------------------------------------------------

# ── Defaults & configuration ──────────────────────────────────────
BASE_BRANCH="${1:-main}"
CLAUDE_CMD="${CLAUDE_CMD:-claude}"
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-opus-4-6}"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "ERROR: must be run inside a git repository." >&2
  exit 1
}

if ! git rev-parse --verify "${BASE_BRANCH}" >/dev/null 2>&1; then
  echo "ERROR: base branch '${BASE_BRANCH}' does not exist." >&2
  exit 1
fi

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || {
  echo "ERROR: no commits on current branch. Cannot run code review." >&2
  exit 1
}

if [ "$CURRENT_BRANCH" = "HEAD" ]; then
  CURRENT_BRANCH="detached at $(git rev-parse --short HEAD)"
  echo "WARNING: detached HEAD state. Using: ${CURRENT_BRANCH}" >&2
fi

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

RESEARCH_FILE="${WORK_DIR}/PR_RESEARCH.md"
DRAFT_FILE="${WORK_DIR}/PR_CODE_REVIEW_DRAFT.md"
echo "── Code Review Pipeline ───────────────────────────────────"
echo "  Repo root      : ${REPO_ROOT}"
echo "  Current branch : ${CURRENT_BRANCH}"
echo "  Base branch    : ${BASE_BRANCH}"
echo "  Claude cmd     : ${CLAUDE_CMD}"
echo "  Model          : ${CLAUDE_MODEL}"
echo "  Working dir    : ${WORK_DIR}"
echo "──────────────────────────────────────────────────────────"
echo ""

# ══════════════════════════════════════════════════════════════════
# STEP 1: Research
# ══════════════════════════════════════════════════════════════════
echo "── Step 1/3: Research ────────────────────────────────────"
echo ""

PROMPT_CONTEXT="CONTEXT:
- Repository root: ${REPO_ROOT}
- Current branch: ${CURRENT_BRANCH}
- Base branch: ${BASE_BRANCH}
- Research output file: ${RESEARCH_FILE}"

PROMPT_BODY=$(cat <<'PROMPT_EOF'

You are performing a deep code review research task.

INSTRUCTIONS:

Use git to examine all changes in this branch (committed, staged, and unstaged) compared to the base branch listed above. Run git diff, git log, and any other git commands you need to understand the full scope of changes.

Research the codebase IN DEPTH to understand the changes. Read every relevant file in full. Understand the architecture, data flow, and all specificities. Do not skim. Do not stop researching until you have a thorough understanding of every part of the codebase the changes touch. Explore related files across the entire repo.

Your ONLY deliverable is writing the research output file listed above.

Write the following sections:

## Summary
A concise summary of what this branch does.

## Changed Files
Every file that has been modified, with brief descriptions of what each does and what changed.

## Commit History
Summary of commits in this branch.

## Existing Patterns
How similar features are currently implemented in this codebase (naming conventions, folder structure, component patterns, API patterns).

## Dependencies
Libraries, utilities, shared code, and services that are relevant to the changes.

## Potential Impact Areas
What else might break or need updating (tests, types, imports, configs).

## Edge Cases and Constraints
Anything tricky that the implementation should watch out for.

## Reference Implementations
If there is a similar feature already built in the codebase, document it as a reference.

## Observations
Any other noteworthy findings, concerns, or suggestions.

Be thorough. Keep researching until you have complete understanding.
PROMPT_EOF
)

PROMPT_RESEARCH="${PROMPT_CONTEXT}
${PROMPT_BODY}"

if ! $CLAUDE_CMD -p "$PROMPT_RESEARCH" --model "$CLAUDE_MODEL" --dangerously-skip-permissions < /dev/null; then
  echo "ERROR: Step 1 failed — claude exited with a non-zero status." >&2
  exit 1
fi

if [ ! -f "$RESEARCH_FILE" ]; then
  echo "ERROR: Step 1 failed — ${RESEARCH_FILE} was not created." >&2
  exit 1
fi
echo ""
echo "  Step 1 complete: ${RESEARCH_FILE}"
echo ""

# ══════════════════════════════════════════════════════════════════
# STEP 2: Draft Code Review
# ══════════════════════════════════════════════════════════════════
echo "── Step 2/3: Draft Code Review ──────────────────────────"
echo ""

PROMPT_CONTEXT="CONTEXT:
- Repository root: ${REPO_ROOT}
- Current branch: ${CURRENT_BRANCH}
- Base branch: ${BASE_BRANCH}
- Research file: ${RESEARCH_FILE}
- Draft output file: ${DRAFT_FILE}"

PROMPT_BODY=$(cat <<'PROMPT_EOF'

You are an expert code reviewer. Your job is to perform a thorough code review.

INSTRUCTIONS:

Read the PR research notes from the research file listed above. Use git to examine all changes in this branch (committed, staged, and unstaged) compared to the base branch. Run git diff, git log, and any other git commands you need.

Make NO assumptions — explore the codebase and verify every assumption made in the code changes. ONLY report issues where you have concrete evidence. Do NOT suggest verification tasks for hypothetical scenarios.

Include file names and line numbers where possible.

Your ONLY deliverable is writing the draft output file listed above. The response must be in markdown.

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

if ! $CLAUDE_CMD -p "$PROMPT_DRAFT" --model "$CLAUDE_MODEL" --dangerously-skip-permissions < /dev/null; then
  echo "ERROR: Step 2 failed — claude exited with a non-zero status." >&2
  exit 1
fi

if [ ! -f "$DRAFT_FILE" ]; then
  echo "ERROR: Step 2 failed — ${DRAFT_FILE} was not created." >&2
  exit 1
fi
echo ""
echo "  Step 2 complete: ${DRAFT_FILE}"
echo ""

# ══════════════════════════════════════════════════════════════════
# STEP 3: Audit & Finalise
# ══════════════════════════════════════════════════════════════════
echo "── Step 3/3: Audit & Finalise ───────────────────────────"
echo ""

PROMPT_CONTEXT="CONTEXT:
- Repository root: ${REPO_ROOT}
- Current branch: ${CURRENT_BRANCH}
- Base branch: ${BASE_BRANCH}
- Research file: ${RESEARCH_FILE}
- Draft review file: ${DRAFT_FILE}"

PROMPT_BODY=$(cat <<'PROMPT_EOF'

You are a senior code review auditor. Your job is to:

1. Review a draft AI-generated code review and identify any issues that are false, speculative, or invalid
2. Produce a final, clean code review containing only validated issues

INSTRUCTIONS:

Read the draft code review from the draft review file listed above. Also read the research file for additional context. Use git to examine all changes in this branch (committed, staged, and unstaged) compared to the base branch. For each issue raised in the draft, verify it against the actual codebase. Explore the codebase to confirm or refute each finding.

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
if ! $CLAUDE_CMD -p "$PROMPT_FINAL" --model "$CLAUDE_MODEL" --dangerously-skip-permissions < /dev/null > "$REVIEW_OUTPUT"; then
  echo "ERROR: Step 3 failed — claude exited with a non-zero status." >&2
  exit 1
fi
echo ""

# ══════════════════════════════════════════════════════════════════
# Done
# ══════════════════════════════════════════════════════════════════
trap - EXIT
echo "── Code Review Complete ─────────────────────────────────"
echo "  Research       : ${RESEARCH_FILE}"
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
