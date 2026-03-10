# claude-sh

A collection of bash scripts that use the Claude CLI (`claude -p`) to perform multi-step AI pipelines against git repositories.

## Script Standards

All scripts in this project MUST follow the patterns established in `code-review.sh`. The conventions below are mandatory.

### Shell Basics

- Shebang: `#!/usr/bin/env bash`
- Always `set -euo pipefail`
- Header comment block describing the script name, what it does (numbered pipeline steps), and usage/options

### Configuration

- `CLAUDE_CMD="${CLAUDE_CMD:-claude}"` — allow overriding the claude binary
- `CLAUDE_MODEL="${CLAUDE_MODEL:-<default>}"` — allow overriding the model via env var
- Support `--model` flag for CLI override where appropriate
- Parse CLI options with a `while/case` loop

### Git Repository Validation

Scripts operate on git repos. Validate early:

```bash
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "ERROR: must be run inside a git repository." >&2
  exit 1
}
```

Detect and handle detached HEAD, missing branches, and clean working trees as appropriate.

### Working Directory

Intermediate files go in a unique temp directory outside the repo:

```bash
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
WORK_DIR="${TMPDIR:-/tmp}/<script-name>-${RUN_ID}"
mkdir -p "$WORK_DIR"
```

- Register a `cleanup` trap on EXIT that removes `$WORK_DIR`
- Support `KEEP_WORK_DIR=1` to preserve files for debugging
- On success, disable the trap (`trap - EXIT`) so output files persist if needed

### Pipeline Banner

Print a summary banner before any work begins:

```
── <Pipeline Name> ───────────────────────────────────
  Repo root      : ...
  Current branch : ...
  ...key config values...
  Working dir    : ...
──────────────────────────────────────────────────────
```

### Claude Invocation

Use a `run_claude` helper to invoke Claude. It handles logging, stderr capture, and diagnostics:

```bash
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
```

- Each step is a fresh Claude session (no conversation state shared between steps)
- Steps pass context to each other via intermediate files in `$WORK_DIR`
- All Claude stdout is appended to `$LOG_FILE` for post-mortem inspection
- Stderr is captured separately and printed inline if non-empty
- Pass a second argument to redirect Claude's stdout to a file (used when the deliverable is stdout rather than a written file)
- Include the log file path in the pipeline banner

### Prompt Structure

Prompts are built from two parts concatenated together:

1. **PROMPT_CONTEXT** — dynamic variables (repo root, branch, file paths). Plain string assignment.
2. **PROMPT_BODY** — static instructions. Use a quoted heredoc (`cat <<'PROMPT_EOF'`) to avoid variable expansion.

```bash
PROMPT_CONTEXT="CONTEXT:
- Repository root: ${REPO_ROOT}
- Output file: ${OUTPUT_FILE}"

PROMPT_BODY=$(cat <<'PROMPT_EOF'
You are ...

INSTRUCTIONS:
...
PROMPT_EOF
)

FULL_PROMPT="${PROMPT_CONTEXT}
${PROMPT_BODY}"
```

- Tell Claude the output file path in the context block
- State the deliverable clearly: "Your ONLY deliverable is writing the output file listed above"
- Use a role preamble: "You are a/an ..."

### Step Progress

Print step headers so the user can follow progress:

```
── Step 1/N: <Step Name> ──────────────────────────
```

### Error Handling

After each `run_claude` invocation:

1. Check the exit code
2. Verify expected output files were created (or non-empty for stdout captures)
3. Print `ERROR:` to stderr, point to the log file, and `exit 1`

```bash
if ! run_claude "$PROMPT"; then
  echo "ERROR: Step N failed — claude exited with a non-zero status." >&2
  echo "  See log: ${LOG_FILE}" >&2
  exit 1
fi

if [ ! -f "$EXPECTED_FILE" ]; then
  echo "ERROR: Step N failed — ${EXPECTED_FILE} was not created." >&2
  echo "  Claude ran but did not write the expected file." >&2
  echo "  See log: ${LOG_FILE}" >&2
  exit 1
fi
```

### Completion

Print a summary of output file locations. Use `glow`, `bat`, or `cat` (in that preference order) to render markdown output:

```bash
if command -v glow >/dev/null 2>&1; then
  glow "$OUTPUT_FILE"
elif command -v bat >/dev/null 2>&1; then
  bat --language md --style plain --paging never "$OUTPUT_FILE"
else
  cat "$OUTPUT_FILE"
fi
```

### Section Separators

Use consistent box-drawing characters for visual structure:

- `══` double lines for major step headers (comment blocks)
- `──` single lines for printed banners and sub-headers
