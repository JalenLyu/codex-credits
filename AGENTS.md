# AGENTS.md

## Operating principles

- Prefer small, reviewable diffs. Avoid sweeping refactors unless explicitly requested.
- Before editing, identify the file(s) to change and state the plan in 3-6 bullets.
- Never invent APIs, configs, or file paths. Search the project first if unsure.
- Keep changes consistent with the existing style and architecture.

## Project context

This project modifies [open-vibe-island (Open Island)](https://github.com/Octane0411/open-vibe-island) to display daily Codex usage in the macOS notch/status bar.

Key references:
- Codex usage data source: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` — direct JSONL parsing
- Open Island architecture: `.claude/memory/open-island-architecture.md`
- Integration plan: `docs/open-island-modification.md`

## Safety and secrets

- Never paste secrets, tokens, private keys, or `.env` values into code or logs.
- If a task requires secrets, ask for them via environment variables.
- Do not add analytics, telemetry, or network calls unless explicitly requested.
- Do not modify external systems such as Confluence or Google Sheets unless explicitly requested.

## Code quality bar

- Add or update tests for behavior changes when the project has tests.
- Prefer explicit error handling and type-safe changes where the stack supports it.
- Add comments only when the intent is non-obvious.

## Output formatting

- For code changes: include a short summary and the files changed.
- For debugging: include hypotheses, experiments run, and the minimal fix.

## Collaboration defaults

- Default explanation language: Chinese.
- Keep explanations concise and operational.
- Ask before deleting local files.
