#!/bin/bash
# uninstall.sh — 完全卸载 Codex Credits Tracker
# 当 Codex 官方开放额度查询后，运行此脚本清理

set -euo pipefail
BOLD="\033[1m"; GREEN="\033[32m"; RESET="\033[0m"

echo -e "${BOLD}🧹 Codex Credits Tracker 卸载${RESET}"
echo ""

# 1. 清理钩子
HOOKS_FILE="$HOME/.codex/hooks.json"
if [ -f "$HOOKS_FILE" ]; then
    python3 -c "
import json
with open('$HOOKS_FILE') as f: config = json.load(f)
h = config.get('hooks', {})
for event in ['PostToolUse', 'Stop']:
    h[event] = [e for e in h.get(event, []) if 'codex-credits' not in json.dumps(e) and 'codex-barrage' not in json.dumps(e)]
with open('$HOOKS_FILE', 'w') as f: json.dump(config, f, indent=2)
" 2>/dev/null
    echo -e "${GREEN}✅ 钩子已清理${RESET}"
fi

# 2. 菜单栏
rm -f "$HOME/Library/SwiftBar/plugins/codex.10s.sh" "$HOME/Library/SwiftBar/plugins/codex.30m.sh"
defaults delete com.ameba.SwiftBar PluginDirectory 2>/dev/null || true
echo -e "${GREEN}✅ SwiftBar 插件及配置已清除${RESET}"

# 3. 别名
sed -i '' '/alias codex=/d' "$HOME/.zshrc" 2>/dev/null || true
echo -e "${GREEN}✅ 别名已移除${RESET}"

# 4. 配置
rm -f "$HOME/.codex-credits.json" "/tmp/codex-credits.json" "/tmp/codex-credits.lock"
echo -e "${GREEN}✅ 配置已删除${RESET}"

echo ""
echo -e "${GREEN}${BOLD}卸载完成${RESET}"
echo "  项目目录请手动删除: rm -rf <项目路径>"
