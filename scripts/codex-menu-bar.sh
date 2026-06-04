#!/bin/bash
# codex-menu-bar.sh — SwiftBar 菜单栏插件
# 读取 /tmp/codex-credits.json 缓存（钩子驱动更新）
# 滚动显示: 美元 / 百分比（交替）

CACHE_FILE="/tmp/codex-credits.json"
SCRIPT_DIR="$(cd "$(dirname "$(readlink "$0" || echo "$0")")" && pwd)"

[ -f "$CACHE_FILE" ] || { echo "⚙️ Codex ..."; exit 0; }

export SCRIPT_DIR
python3 -c "
import json, os, time

with open('$CACHE_FILE') as f:
    c = json.load(f)

dol      = c.get('dollars_used', 0)
budget   = c.get('dollars_limit', 0) or c.get('weekly_budget_dollars', 0)
fresh    = c.get('fresh_input', 0)
out      = c.get('output', 0)
cached   = c.get('cached', 0)
events   = c.get('events', 0)
models   = c.get('models', [])
updated  = c.get('updated_at', '')
p_start  = c.get('period_start', '')[:10]
p_end    = c.get('period_end', '')[:10]
upd_time = updated[11:19] if len(updated) > 19 else updated

has_budget = budget > 0
pct = (dol / budget * 100) if has_budget else 0

# 颜色
def color(p):
    if p >= 90: return chr(128308)  # 🔴
    if p >= 70: return chr(128992)  # 🟠
    if p >= 40: return chr(128993)  # 🟡
    return chr(128994)  # 🟢

def s(n):
    if n >= 1_000_000: return f'{n/1_000_000:.1f}M'
    if n >= 1_000: return f'{n/1_000:.0f}K'
    return str(n)

models_str = ', '.join(models[:3]) if models else '—'
icon = color(pct) if has_budget else chr(128994)

# ── 标题：每隔 30 秒切换美元/百分比 ──
tick = int(time.time()) // 5  # 每 5 秒切换
show_pct = has_budget and (tick % 2 == 1)  # 奇数周期显示百分比

if show_pct:
    title = f'{icon} Codex {int(round(pct))}%'
else:
    title = f'{icon} Codex \${dol:.0f}'

# 如果有预算且超过阈值，加重显示
if has_budget:
    if pct >= 90:
        title += ' | color=red'
    elif pct >= 70:
        title += ' | color=orange'

print(title)

# ── 下拉面板 ──
print('---')
if has_budget:
    bar_len = 10
    filled = max(1, min(bar_len, int(round(bar_len * pct / 100))))
    bar = chr(9608) * filled + chr(9633) * (bar_len - filled)  # ██████□□□□  实心+空心方块
    remaining = budget - dol
    print(f'{icon} {bar}  {pct:.1f}%')
    print(f'   \${dol:.2f} / \${budget:.2f}  ·  剩余 \${remaining:.2f}')
else:
    print(f'{icon} 本周已花费 \${dol:.2f}')
    print('')
    print('💡 设置预算以显示百分比: codex --set-budget')

print('---')
print(f'📦 输入 {s(fresh)}  ·  输出 {s(out)}  ·  缓存 {s(cached)}')
print(f'📅 {p_start} → {p_end}')
print(f'⏰ {upd_time}  ·  {events} 次调用  ·  {models_str}')

# SwiftBar 提供插件路径，反推脚本目录
plugin_dir = os.environ.get('SWIFTBAR_PLUGIN_PATH', '')
if plugin_dir and os.path.islink(plugin_dir):
    script_dir = os.path.dirname(os.path.realpath(plugin_dir))
else:
    script_dir = os.environ.get('SCRIPT_DIR', os.path.expanduser('~'))

cache_script = os.path.join(script_dir, 'codex-credits-cache.sh')
main_script  = os.path.join(script_dir, 'daily-usage.sh')

print('---')
if os.path.isfile(cache_script):
    print(f'🔄 刷新数据 | bash={cache_script} param1=--hook terminal=false refresh=true')
if os.path.isfile(main_script):
    print(f'📋 详细报告 | bash={main_script} param1=--weekly terminal=true')
print(f'⚙️ 设置预算 | bash={main_script} param1=--set-budget terminal=true')
"
