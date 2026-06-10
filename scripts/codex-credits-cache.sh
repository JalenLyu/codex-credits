#!/bin/bash
# codex-credits-cache.sh — refresh /tmp/codex-credits.json for SwiftBar/hooks.

set -euo pipefail

LOCK_FILE="/tmp/codex-credits.lock"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$LOCK_FILE" ] && [ -n "$(find "$LOCK_FILE" -mmin -1 2>/dev/null || true)" ]; then
    exit 0
fi

touch "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

python3 "$SCRIPT_DIR/codex_credits_core.py" cache
