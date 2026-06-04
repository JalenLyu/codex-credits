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

# ── 配置 ──
cat > "$HOME/.codex-credits.json" << EOF
{
  "weekly_budget_dollars": 0,
  "tokens_per_credit": 3900,
  "cents_per_credit": 4,
  "output_token_weight": 1,
  "cached_token_weight": 0,
  "reset_weekday": "$RESET_WEEKDAY",
  "reset_hour": $RESET_HOUR,
  "reset_minute": $RESET_MINUTE
}
EOF

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

echo -e "${GREEN}✅ 菜单栏插件已安装到 $PLUGIN_DIR${RESET}"
echo "   安装 SwiftBar 后自动出现: brew install --cask swiftbar"

# ── 弹幕（可选） ──
case "$MODE" in
    --with-barrage)
        echo ""
        echo -e "${CYAN}📢 弹幕模式${RESET}"

        HOOKS_FILE="$HOME/.codex/hooks.json"
        python3 -c "
import json
try:
    with open('$HOOKS_FILE') as f: config = json.load(f)
except: config = {'hooks': {}}
h = config.setdefault('hooks', {})

# PostToolUse: 刷新缓存（菜单栏和弹幕共用）
pt = h.setdefault('PostToolUse', [])
if not any('codex-credits-cache.sh' in json.dumps(x) for x in pt):
    pt.append({'hooks': [{'command': '/bin/bash $PROJ_DIR/scripts/codex-credits-cache.sh', 'timeout': 30, 'type': 'command'}]})
    print('PostToolUse 钩子已添加')

# Stop: 弹幕通知
st = h.setdefault('Stop', [])
if not any('codex-barrage.sh' in json.dumps(x) for x in st):
    st.append({'hooks': [{'command': '/bin/bash $PROJ_DIR/scripts/codex-barrage.sh', 'timeout': 10, 'type': 'command'}]})
    print('Stop 弹幕钩子已添加')

with open('$HOOKS_FILE', 'w') as f: json.dump(config, f, indent=2)
" 2>/dev/null
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
echo "  菜单栏:   brew install --cask swiftbar (自动配置)"
if [ "$MODE" = "--with-barrage" ]; then
    echo "  弹幕:     会话结束自动弹出"
fi
echo ""
echo "  重新安装:  bash install.sh --with-barrage"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
