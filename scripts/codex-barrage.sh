#!/bin/bash
# codex-barrage.sh — Codex usage notification, triggered by Stop hooks.

set -euo pipefail

SOURCE="$0"
if TARGET="$(readlink "$SOURCE" 2>/dev/null)"; then
    SOURCE="$TARGET"
fi
SCRIPT_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"

sleep 1

PAYLOAD="$(python3 "$SCRIPT_DIR/codex_credits_core.py" barrage 2>/dev/null || true)"
[ -n "$PAYLOAD" ] || exit 0

TITLE="$(PAYLOAD="$PAYLOAD" python3 -c 'import json, os; print(json.loads(os.environ["PAYLOAD"]).get("title", ""))' 2>/dev/null || true)"
SUBTITLE="$(PAYLOAD="$PAYLOAD" python3 -c 'import json, os; print(json.loads(os.environ["PAYLOAD"]).get("subtitle", ""))' 2>/dev/null || true)"
BODY="$(PAYLOAD="$PAYLOAD" python3 -c 'import json, os; print(json.loads(os.environ["PAYLOAD"]).get("body", ""))' 2>/dev/null || true)"

[ -n "$TITLE" ] || exit 0

TITLE="$TITLE" SUBTITLE="$SUBTITLE" BODY="$BODY" osascript <<'APPLESCRIPT' 2>/dev/null || true
set notificationTitle to system attribute "TITLE"
set notificationSubtitle to system attribute "SUBTITLE"
set notificationBody to system attribute "BODY"
display notification notificationBody with title notificationTitle subtitle notificationSubtitle
APPLESCRIPT
