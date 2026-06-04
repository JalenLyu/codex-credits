#!/bin/bash
# codex-barrage.sh — Codex 弹幕通知
# 由 ~/.codex/hooks.json 的 Stop 事件触发

CACHE_FILE="/tmp/codex-credits.json"
sleep 1

[ -f "$CACHE_FILE" ] || exit 0

read -r ICON TITLE SUBTITLE BODY <<<$(python3 -c "
import json

with open('$CACHE_FILE') as f:
    c = json.load(f)

dol    = c.get('dollars_used', 0)
budget   = c.get('dollars_limit', 0) or c.get('weekly_budget_dollars', 0)
fresh  = c.get('fresh_input', 0)
out    = c.get('output', 0)
models = c.get('models', [])

has_budget = budget > 0
pct = (dol / budget * 100) if has_budget else 0

if has_budget and pct >= 90:
    icon = chr(128308)  # 🔴
    tag = chr(9888) + chr(65039)  # ⚠️
    status = '额度即将用尽'
elif has_budget and pct >= 70:
    icon = chr(128992)  # 🟠
    tag = chr(9889)  # ⚡
    status = '用量警告'
elif has_budget and pct >= 40:
    icon = chr(128993)  # 🟡
    tag = chr(8226)  # •
    status = '用量中等'
else:
    icon = chr(128994)  # 🟢
    tag = chr(10003)  # ✓
    status = '用量正常'

def s(n):
    if n >= 1_000_000: return f'{n/1_000_000:.1f}M'
    if n >= 1000: return f'{n/1000:.0f}K'
    return str(n)

model_str = ', '.join(models[:2]) if models else '通用'

# 标题：美金为主
title = f'{icon} Codex 本周'

# 副标题：花费金额
subtitle = f'{tag} 已花费 \${dol:.2f}'
if has_budget:
    subtitle += f'  /  \${budget:.2f} ({int(round(pct))}%)'

# 正文
body = f'输入 {s(fresh)}  ·  输出 {s(out)}  ·  {model_str}'

print(icon)
print(title)
print(subtitle)
print(body)
" 2>/dev/null)

[ -z "$TITLE" ] && exit 0

osascript -e "
display notification \"$BODY\" with title \"$TITLE\" subtitle \"$SUBTITLE\"
" 2>/dev/null
