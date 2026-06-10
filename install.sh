#!/bin/bash
# install.sh — Codex Credits Tracker 安装
#
# 用法:
#   bash install.sh                    # 菜单栏模式（默认）
#   bash install.sh --with-barrage     # 菜单栏 + 弹幕通知

set -euo pipefail

BOLD="\033[1m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

MODE="${1:---menu}"

echo -e "${BOLD}🏝️  Codex Credits Tracker 安装${RESET}"
echo ""

# ── 找到项目目录 ──
[ -f "./scripts/daily-usage.sh" ] || { echo "请先克隆: git clone https://github.com/JalenLyu/codex-credits.git"; exit 1; }
PROJ_DIR="$(pwd)"

# ── 探测计费起点 ──
echo "🔍 探测计费起点..."
eval "$(python3 -c "
import json, glob, os
from datetime import datetime, timedelta, timezone

CST = timezone(timedelta(hours=8))
BILLING = datetime(2026, 5, 27, 12, 0, 0, tzinfo=CST)
sessions = os.path.expanduser('~/.codex/sessions')
files = sorted(glob.glob(os.path.join(sessions, '2***', '*', '*', 'rollout-*.jsonl')))

earliest = None
for f in files:
    try:
        with open(f) as fh:
            for line in fh:
                parsed = json.loads(line)
                if parsed.get('type') == 'event_msg':
                    pt = parsed.get('payload', {})
                    if isinstance(pt, dict) and pt.get('type') == 'token_count':
                        ts = parsed.get('timestamp', '')
                        if ts:
                            dt = datetime.fromisoformat(ts.replace('Z', '+00:00')).astimezone(CST)
                            if dt >= BILLING and (earliest is None or dt < earliest):
                                earliest = dt
    except: pass

if earliest:
    print(f'RESET_WEEKDAY={earliest.strftime(\"%A\")}')
    print(f'RESET_HOUR={earliest.hour}')
    print(f'RESET_MINUTE={earliest.minute:02d}')
    print(f'FIRST_DATE={earliest.strftime(\"%Y-%m-%d\")}')
    print(f'FOUND=1')
else:
    print('RESET_WEEKDAY=Thursday')
    print('RESET_HOUR=15')
    print('RESET_MINUTE=00')
    print('FOUND=0')
")"

[ "${FOUND:-0}" = "1" ] && echo -e "${GREEN}✅ $FIRST_DATE $RESET_WEEKDAY ${RESET_HOUR}:${RESET_MINUTE} CST${RESET}" || echo -e "${YELLOW}⚠️  使用默认${RESET}"

# ── 配置：只补缺省值，不覆盖用户已有校准 ──
export RESET_WEEKDAY RESET_HOUR RESET_MINUTE
python3 - <<'PYEOF'
import json
import os
from pathlib import Path

path = Path.home() / ".codex-credits.json"
try:
    config = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(config, dict):
        config = {}
except (OSError, json.JSONDecodeError):
    config = {}

defaults = {
    "weekly_budget_dollars": 75,
    "weekly_credits": 1875,
    "tokens_per_credit": 3981,
    "cents_per_credit": 4,
    "output_token_weight": 0,
    "cached_token_weight": 0,
    "reset_weekday": os.environ.get("RESET_WEEKDAY", "Wednesday"),
    "reset_hour": int(os.environ.get("RESET_HOUR", "15")),
    "reset_minute": int(os.environ.get("RESET_MINUTE", "16")),
}

for key, value in defaults.items():
    config.setdefault(key, value)

path.write_text(json.dumps(config, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
PYEOF
echo -e "${GREEN}✅ 配置已初始化/保留${RESET}"

# ── 终端别名 ──
ALIAS_LINE="alias codex='bash $PROJ_DIR/scripts/daily-usage.sh'"
ZSHRC="$HOME/.zshrc"
touch "$ZSHRC"
grep -q "alias codex=" "$ZSHRC" 2>/dev/null && sed -i.bak "s|alias codex=.*|${ALIAS_LINE}|" "$ZSHRC" || echo "$ALIAS_LINE" >> "$ZSHRC"
echo -e "${GREEN}✅ codex 别名已添加${RESET}"

# ── 菜单栏（自动配置，无需手动选文件夹） ──
PLUGIN_DIR="$HOME/Library/SwiftBar/plugins"
SWIFTBAR_PREFS="$HOME/Library/Preferences/com.ameba.SwiftBar.plist"

mkdir -p "$PLUGIN_DIR"
ln -sf "$PROJ_DIR/scripts/codex-menu-bar.sh" "$PLUGIN_DIR/codex.10s.sh"

# 提前设好插件目录，SwiftBar 启动不会弹选择框
defaults write com.ameba.SwiftBar PluginDirectory "$PLUGIN_DIR" 2>/dev/null || true

echo -e "${GREEN}✅ 菜单栏插件已安装${RESET}"

# 自动启动 SwiftBar
if [ -d "/Applications/SwiftBar.app" ]; then
    open -a SwiftBar 2>/dev/null && echo -e "${GREEN}✅ SwiftBar 已启动${RESET}" || true
else
    echo "   brew install --cask swiftbar && open -a SwiftBar"
fi

# ── Codex 钩子：默认刷新缓存，弹幕可选 ──
HOOKS_FILE="$HOME/.codex/hooks.json"
export HOOKS_FILE PROJ_DIR MODE
python3 - <<'PYEOF'
import json
import os
from pathlib import Path

hooks_file = Path(os.environ["HOOKS_FILE"])
proj_dir = os.environ["PROJ_DIR"]
mode = os.environ["MODE"]
hooks_file.parent.mkdir(parents=True, exist_ok=True)

try:
    config = json.loads(hooks_file.read_text(encoding="utf-8"))
    if not isinstance(config, dict):
        config = {"hooks": {}}
except (OSError, json.JSONDecodeError):
    config = {"hooks": {}}

hooks = config.setdefault("hooks", {})

post_tool_use = hooks.setdefault("PostToolUse", [])
cache_command = f"/bin/bash {proj_dir}/scripts/codex-credits-cache.sh"
if not any("codex-credits-cache.sh" in json.dumps(item) for item in post_tool_use):
    post_tool_use.append({"hooks": [{"command": cache_command, "timeout": 30, "type": "command"}]})
    print("PostToolUse 缓存钩子已添加")

if mode == "--with-barrage":
    stop_hooks = hooks.setdefault("Stop", [])
    barrage_command = f"/bin/bash {proj_dir}/scripts/codex-barrage.sh"
    if not any("codex-barrage.sh" in json.dumps(item) for item in stop_hooks):
        stop_hooks.append({"hooks": [{"command": barrage_command, "timeout": 10, "type": "command"}]})
        print("Stop 弹幕钩子已添加")

hooks_file.write_text(json.dumps(config, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
PYEOF
echo -e "${GREEN}✅ 缓存刷新钩子已安装${RESET}"

# ── 弹幕（可选） ──
case "$MODE" in
    --with-barrage)
        echo ""
        echo -e "${CYAN}📢 弹幕模式${RESET}"
        echo -e "${GREEN}✅ 弹幕钩子已安装${RESET}"
        echo "   每次 Codex 会话结束自动弹出"
        ;;
esac

# ── 首次缓存 ──
bash "$PROJ_DIR/scripts/codex-credits-cache.sh" 2>/dev/null || true

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${GREEN}${BOLD} ✅ 完成${RESET}"
echo ""
echo "  终端:     source ~/.zshrc && codex"
echo "  菜单栏显示:"
echo "    1. 未安装 SwiftBar: brew install --cask swiftbar && open -a SwiftBar"
echo "    2. 已安装 SwiftBar: 打开 SwiftBar 后会自动读取插件目录"
echo "    3. 没出现时: SwiftBar 菜单中点 Refresh All，或确认插件路径:"
echo "       $PLUGIN_DIR/codex.10s.sh"
echo "    4. 手动预览: bash $PROJ_DIR/scripts/codex-menu-bar.sh"
if [ "$MODE" = "--with-barrage" ]; then
    echo "  弹幕:     会话结束自动弹出"
fi
echo ""
echo "  重新安装:  bash install.sh --with-barrage"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
