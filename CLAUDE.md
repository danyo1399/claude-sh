# claude-sh

A collection of bash scripts that use the Claude CLI (`claude -p`) or OpenCode CLI (`opencode run`) to perform multi-step AI pipelines against git repositories.

## File Naming Conventions

- Claude scripts are prefixed with `cc` (e.g., `cccodereview.sh`)
- Open code scripts are prefixed with `oc` (e.g., `ocexample.sh`)

## Directory Structure

Scripts are organised into category folders: `claude/` for `cc` scripts and `opencode/` for `oc` scripts. Each category folder contains a `draft/` subfolder for scripts that are not yet ready for production use. Draft scripts are excluded from installation.

## Script Standards

All scripts in this project MUST follow the patterns established in `code-review.sh`. The conventions below are mandatory.

### Shell Basics

- Shebang: `#!/usr/bin/env bash`
- Always `set -euo pipefail`
- Header comment block describing the script name, what it does (numbered pipeline steps), and usage/options

### Help / Usage

Every script MUST provide a `usage()` function printed on `-h` or `--help`. The help text must include:

- **Description** — what the script does (1–2 sentences)
- **Usage** — `Usage: script-name [OPTIONS] [ARGS]`
- **Options** — every flag/env-var the script accepts, with defaults noted
- **Environment variables** — any env vars that influence behaviour (e.g. `CLAUDE_CMD`, `CLAUDE_MODEL`, `KEEP_WORK_DIR`)
- **Examples** — at least two realistic invocation examples

The `--help` check must come before any validation (git checks, argument parsing) so help works outside a repo.

```bash
usage() {
  cat <<EOF
Description of the script.

Usage: script-name [OPTIONS] [ARGS]

Options:
  -h, --help           Show this help message and exit
  --model MODEL        Model to use (e.g. claude-opus-4-6)
  --claude-cmd CMD     Path to claude binary (default: claude)

Environment variables:
  CLAUDE_CMD           Path to claude binary (default: claude); --claude-cmd takes precedence
  CLAUDE_MODEL         Model override (e.g. claude-opus-4-6); --model flag takes precedence
  KEEP_WORK_DIR        Set to 1 to preserve temp files on failure

Examples:
  script-name
  script-name --model claude-sonnet-4-20250514 develop
EOF
}
```

Parse `-h`/`--help` early in the `while/case` option loop and call `usage; exit 0`.

> **Note:** The example above uses Claude (`cc`) variable names. For OpenCode (`oc`) scripts, substitute `--opencode-cmd`, `OPENCODE_CMD`, and `OPENCODE_MODEL` accordingly. See the Configuration section for details.

### Configuration

Scripts MUST NOT hardcode a default model. The model is either passed via `--model` flag / env var, or the agent harness's default model is used. When no model is specified, omit `--model` from the invocation entirely.

For Claude (`cc`) scripts:
- `CLAUDE_CMD="${CLAUDE_CMD:-claude}"` — allow overriding the claude binary
- `CLAUDE_MODEL="${CLAUDE_MODEL:-}"` — optional model override via env var
- Support `--model` flag for CLI override where appropriate
- Support `--claude-cmd` flag for CLI override of the claude binary

For OpenCode (`oc`) scripts:
- `OPENCODE_CMD="${OPENCODE_CMD:-opencode}"` — allow overriding the opencode binary
- `OPENCODE_MODEL="${OPENCODE_MODEL:-}"` — optional model override via env var (provider/model format)
- Support `--model` flag for CLI override where appropriate
- Support `--opencode-cmd` flag for CLI override of the opencode binary

Both:
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
WORK_DIR="${TMPDIR:-/tmp}"
WORK_DIR="${WORK_DIR%/}/<script-name>-${RUN_ID}"
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

### Claude Invocation (cc scripts)

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

  local model_args=()
  if [ -n "$CLAUDE_MODEL" ]; then
    model_args=(--model "$CLAUDE_MODEL")
  fi

  if [ -n "$stdout_file" ]; then
    $CLAUDE_CMD -p "$prompt" ${model_args[@]+"${model_args[@]}"} --dangerously-skip-permissions \
      < /dev/null 2>"$stderr_file" | tee -a "$LOG_FILE" > "$stdout_file" || exit_code=$?
  else
    $CLAUDE_CMD -p "$prompt" ${model_args[@]+"${model_args[@]}"} --dangerously-skip-permissions \
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

### OpenCode Invocation (oc scripts)

OpenCode scripts use `opencode run` instead of `claude -p`. Documentation: https://opencode.ai/docs/cli/#run-1

**CLI syntax:** `opencode run [message..] [flags]`

Key flags:
- `--model, -m` — model in `provider/model` format (e.g., `opencode/claude-opus-4-6`)
- `--dangerously-skip-permissions` — auto-approve permissions not explicitly denied
- `--file, -f` — file(s) to attach to message
- `--format` — `default` (formatted) or `json` (raw JSON events)
- `--continue, -c` — continue the last session
- `--session, -s` — session ID to continue
- `--fork` — fork session when continuing
- `--share` — share the session
- `--agent` — agent to use
- `--title` — title for the session
- `--attach` — attach to a running opencode server (e.g., `http://localhost:4096`)
- `--port` — port for the local server
- `--dir` — directory to run in
- `--variant` — model variant / reasoning effort (e.g., `high`, `max`, `minimal`)
- `--thinking` — show thinking blocks

Use a `run_opencode` helper that mirrors `run_claude`:

```bash
LOG_FILE="${WORK_DIR}/opencode.log"

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
```

Refer to the Configuration section above for `oc` script variable and flag conventions.

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
