#!/bin/bash
# daily-usage.sh — Codex usage CLI wrapper.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec python3 "$SCRIPT_DIR/codex_credits_core.py" "$@"
