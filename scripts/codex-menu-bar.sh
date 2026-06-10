#!/bin/bash
# codex-menu-bar.sh — SwiftBar plugin wrapper.

set -euo pipefail

SOURCE="$0"
if TARGET="$(readlink "$SOURCE" 2>/dev/null)"; then
    SOURCE="$TARGET"
fi
SCRIPT_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"

export SCRIPT_DIR
exec python3 "$SCRIPT_DIR/codex_credits_core.py" menu
