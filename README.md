# claude-sh

A collection of bash scripts that use the Claude CLI (`claude -p`), OpenCode CLI (`opencode run`), or Codex CLI (`codex exec`) to perform multi-step AI pipelines against git repositories.

## Overview

This project provides automated pipelines for common software engineering tasks (like code reviews, estimations, and commits) by leveraging powerful LLM CLIs. It is designed to work seamlessly within git repositories.

## Directory Structure

Scripts are organized into category folders:
- `claude/`: Contains `cc` scripts (Claude-based).
- `opencode/`: Contains `oc` scripts (OpenCode-based).
- `codex/`: Contains `cx` scripts (Codex-based).
- Each folder contains a `draft/` subfolder for scripts not yet ready for production.

## Key Concepts

### Naming Conventions
- **Claude scripts**: Prefixed with `cc` (e.g., `cccodereview.sh`).
- **OpenCode scripts**: Prefixed with `oc` (e.g., `occodereview.sh`).
- **Codex scripts**: Prefixed with `cx` (e.g., `cxcodereview.sh`).

### Script Sync Policy

Every non-draft Claude script (`cc`) has a corresponding OpenCode (`oc`) equivalent in `opencode/` and a corresponding Codex (`cx`) equivalent in `codex/`. The three versions are functionally identical, differing only in naming and invocation methods to ensure parity across different CLI tools.

## Usage

### Running Scripts

Scripts can be run directly from your terminal. Most scripts support flags for model selection and environment overrides.

#### Claude Scripts Example
```bash
./claude/cccodereview.sh --model claude-3-5-sonnet
```

#### OpenCode Scripts Example
```bash
./opencode/occodereview.sh --model opencode/claude-3-5-sonnet
```

#### Codex Scripts Example
```bash
./codex/cxcodereview.sh --model gpt-5-codex
```

### Configuration

You can influence script behavior using environment variables:
- `CLAUDE_CMD` / `OPENCODE_CMD` / `CODEX_CMD`: Path to the respective binary.
- `CLAUDE_MODEL` / `OPENCODE_MODEL` / `CODEX_MODEL`: Model override.
- `KEEP_WORK_DIR=1`: Set to 1 to preserve temporary files on failure for debugging.

## Standards and Quality

All scripts follow strict standards defined in `CLAUDE.md` to ensure reliability:
- **Git Validation**: Scripts validate they are running within a git repository.
- **Work Directories**: Intermediate files are stored in unique temporary directories to prevent clutter.
- **Logging**: All outputs and errors are logged for post-mortem analysis.
