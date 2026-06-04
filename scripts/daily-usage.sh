#!/bin/bash
# daily-usage.sh — Codex 每日用量 & 企业版 Credits 追踪
#
# 直接从 ~/.codex/sessions/ 和 archived_sessions 解析 rollout JSONL，
# 计算 token 用量 → 换算为 credits（企业版 1,875 credits/周 = $75/周）
#
# 使用方法:
#   ./daily-usage.sh                  # 本周用量摘要
#   ./daily-usage.sh --weekly         # 本周详细汇总
#   ./daily-usage.sh --daily          # 每日明细
#   ./daily-usage.sh --auto-detect   # 自动探测计费起算时间
#   ./daily-usage.sh --set-reset      # 手动设置重置时间
#   ./daily-usage.sh --watch          # 持续监控

set -euo pipefail

SESSION_DIR="$HOME/.codex/sessions"
ARCHIVE_DIR="$HOME/.codex/archived_sessions"
CONFIG_FILE="$HOME/.codex-credits.json"

# 默认配置
WEEKLY_CREDITS=1875
TOKENS_PER_CREDIT=3981
CENTS_PER_CREDIT=4
OUTPUT_TOKEN_WEIGHT=1
CACHED_TOKEN_WEIGHT=0

RESET_WEEKDAY="Wednesday"
RESET_HOUR=15
RESET_MINUTE=16

# 读取配置
if [ -f "$CONFIG_FILE" ]; then
    # 用 Python 读取配置并导出为 shell 变量
    CFG_JSON=$(python3 -c "
import json
c = json.load(open('$CONFIG_FILE'))
print(json.dumps({
    'reset_weekday': c.get('reset_weekday','Wednesday'),
    'reset_hour': c.get('reset_hour',15),
    'reset_minute': c.get('reset_minute',16),
    'weekly_credits': c.get('weekly_credits',1875),
    'tokens_per_credit': c.get('tokens_per_credit',3981),
    'cents_per_credit': c.get('cents_per_credit',4),
    'output_token_weight': c.get('output_token_weight',0),
    'cached_token_weight': c.get('cached_token_weight',0),
}))
" 2>/dev/null || echo '{}')
    if [ -n "$CFG_JSON" ]; then
        RESET_WEEKDAY=$(echo "$CFG_JSON" | python3 -c "import json,sys;print(json.load(sys.stdin).get('reset_weekday','Wednesday'))" 2>/dev/null || echo "Wednesday")
        RESET_HOUR=$(echo "$CFG_JSON" | python3 -c "import json,sys;print(json.load(sys.stdin).get('reset_hour',15))" 2>/dev/null || echo "15")
        RESET_MINUTE=$(echo "$CFG_JSON" | python3 -c "import json,sys;print(json.load(sys.stdin).get('reset_minute',16))" 2>/dev/null || echo "16")
        WEEKLY_CREDITS=$(echo "$CFG_JSON" | python3 -c "import json,sys;print(json.load(sys.stdin).get('weekly_credits',1875))" 2>/dev/null || echo "1875")
        TOKENS_PER_CREDIT=$(echo "$CFG_JSON" | python3 -c "import json,sys;print(json.load(sys.stdin).get('tokens_per_credit',3981))" 2>/dev/null || echo "3981")
        CENTS_PER_CREDIT=$(echo "$CFG_JSON" | python3 -c "import json,sys;print(json.load(sys.stdin).get('cents_per_credit',4))" 2>/dev/null || echo "4")
        OUTPUT_TOKEN_WEIGHT=$(echo "$CFG_JSON" | python3 -c "import json,sys;print(json.load(sys.stdin).get('output_token_weight',0))" 2>/dev/null || echo "0")
        CACHED_TOKEN_WEIGHT=$(echo "$CFG_JSON" | python3 -c "import json,sys;print(json.load(sys.stdin).get('cached_token_weight',0))" 2>/dev/null || echo "0")
        WEEKLY_BUDGET_DOLLARS=$(echo "$CFG_JSON" | python3 -c "import json,sys;print(json.load(sys.stdin).get('weekly_budget_dollars',0))" 2>/dev/null || echo "0")
    fi
fi
WEEKLY_BUDGET_DOLLARS="${WEEKLY_BUDGET_DOLLARS:-0}"

export SESSION_DIR ARCHIVE_DIR WEEKLY_CREDITS TOKENS_PER_CREDIT CENTS_PER_CREDIT
export OUTPUT_TOKEN_WEIGHT CACHED_TOKEN_WEIGHT WEEKLY_BUDGET_DOLLARS
export RESET_WEEKDAY RESET_HOUR RESET_MINUTE CONFIG_FILE

# 传递命令行参数
export CLI_ARGS="${*:-}"

# === Python 主逻辑 ===
exec python3 <<'PYEOF'
import json, glob, sys, os
from datetime import datetime, timedelta, timezone
from collections import defaultdict

SESSION_DIR = os.path.expanduser(os.environ['SESSION_DIR'])
ARCHIVE_DIR = os.path.expanduser(os.environ['ARCHIVE_DIR'])
WEEKLY_CREDITS = int(os.environ['WEEKLY_CREDITS'])
TOKENS_PER_CREDIT = int(os.environ['TOKENS_PER_CREDIT'])
CENTS_PER_CREDIT = int(os.environ['CENTS_PER_CREDIT'])
OUTPUT_TOKEN_WEIGHT = float(os.environ['OUTPUT_TOKEN_WEIGHT'])
CACHED_TOKEN_WEIGHT = float(os.environ['CACHED_TOKEN_WEIGHT'])
WEEKLY_BUDGET_DOLLARS = float(os.environ.get('WEEKLY_BUDGET_DOLLARS', '0') or '0')
CONFIG_FILE = os.environ.get('CONFIG_FILE', '')
ARGS = os.environ.get('CLI_ARGS', '').split()
CST = timezone(timedelta(hours=8))

all_files = sorted(
    glob.glob(os.path.join(SESSION_DIR, '2***', '*', '*', 'rollout-*.jsonl')) +
    glob.glob(os.path.join(ARCHIVE_DIR, 'rollout-*.jsonl'))
)

daily = {}
for f in all_files:
    try:
        with open(f) as fh:
            current_model = None
            for line in fh:
                parsed = json.loads(line)
                t = parsed.get('type', '')

                if t == 'turn_context':
                    pl = parsed.get('payload', {})
                    if isinstance(pl, dict):
                        cm = pl.get('model') or pl.get('model_name') or ''
                        if cm:
                            current_model = cm

                if t == 'event_msg':
                    pt = parsed.get('payload', {})
                    if isinstance(pt, dict) and pt.get('type') == 'token_count':
                        info = pt.get('info')
                        if info and isinstance(info, dict) and info.get('last_token_usage'):
                            ltu = info['last_token_usage']
                            ts_utc = parsed.get('timestamp', '')
                            if not ts_utc:
                                continue
                            dt_cst = datetime.fromisoformat(ts_utc.replace('Z', '+00:00')).astimezone(CST)
                            day_key = dt_cst.strftime('%Y-%m-%d')

                            if day_key not in daily:
                                daily[day_key] = {'fresh_input': 0, 'output': 0, 'cached': 0, 'events': 0, 'models': set()}

                            ti = ltu.get('input_tokens', 0) or 0
                            ca = ltu.get('cached_input_tokens', 0) or 0
                            ou = ltu.get('output_tokens', 0) or 0
                            daily[day_key]['fresh_input'] += max(0, ti - ca)
                            daily[day_key]['output'] += ou
                            daily[day_key]['cached'] += ca
                            daily[day_key]['events'] += 1
                            if current_model:
                                daily[day_key]['models'].add(current_model)
    except (json.JSONDecodeError, KeyError, UnicodeDecodeError):
        pass

now_cst = datetime.now(CST)
today_cst = now_cst.strftime('%Y-%m-%d')

# 计算当前重置周期开始时间（滚动周，从个人重置时间算起）
WEEKDAYS = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday']
reset_wd = os.environ.get('RESET_WEEKDAY', 'Wednesday')
reset_hr = int(os.environ.get('RESET_HOUR', 15))
reset_min = int(os.environ.get('RESET_MINUTE', 16))
reset_wd_num = WEEKDAYS.index(reset_wd)

# 找最近一次重置时间
current_wd = now_cst.weekday()
days_since_reset = (current_wd - reset_wd_num) % 7
period_start = now_cst - timedelta(days=days_since_reset)
period_start = period_start.replace(hour=reset_hr, minute=reset_min, second=0, microsecond=0)

# 如果当前时间在重置之前，说明重置是上周的
if now_cst < period_start:
    period_start -= timedelta(days=7)

period_start_str = period_start.strftime('%Y-%m-%dT%H:%M')
period_end_str = now_cst.strftime('%Y-%m-%d %H:%M')

# 按重置周期筛选事件
period_dates = []
events_in_period = {'fresh_input': 0, 'output': 0, 'cached': 0, 'events': 0}
all_models = set()

for f in all_files:
    try:
        with open(f) as fh:
            current_model = None
            for line in fh:
                parsed = json.loads(line)
                t = parsed.get('type', '')

                if t == 'turn_context':
                    pl = parsed.get('payload', {})
                    if isinstance(pl, dict):
                        cm = pl.get('model') or pl.get('model_name') or ''
                        if cm:
                            current_model = cm

                if t == 'event_msg':
                    pt = parsed.get('payload', {})
                    if isinstance(pt, dict) and pt.get('type') == 'token_count':
                        info = pt.get('info')
                        if info and isinstance(info, dict) and info.get('last_token_usage'):
                            ts_utc = parsed.get('timestamp', '')
                            if not ts_utc:
                                continue
                            dt_cst = datetime.fromisoformat(ts_utc.replace('Z', '+00:00')).astimezone(CST)
                            if dt_cst < period_start:
                                continue

                            ltu = info['last_token_usage']
                            ti = ltu.get('input_tokens', 0) or 0
                            ca = ltu.get('cached_input_tokens', 0) or 0
                            ou = ltu.get('output_tokens', 0) or 0
                            events_in_period['fresh_input'] += max(0, ti - ca)
                            events_in_period['output'] += ou
                            events_in_period['cached'] += ca
                            events_in_period['events'] += 1

                            if current_model:
                                all_models.add(current_model)
    except (json.JSONDecodeError, KeyError, UnicodeDecodeError):
        pass

# 获取周期内的日期列表
period_dates = sorted(d for d in daily.keys() if d >= period_start.strftime('%Y-%m-%d'))
rolling = events_in_period
billable_units = (
    rolling['fresh_input'] +
    rolling['output'] * OUTPUT_TOKEN_WEIGHT +
    rolling['cached'] * CACHED_TOKEN_WEIGHT
)
credits_used = billable_units / TOKENS_PER_CREDIT
credits_pct = min(100.0, credits_used / WEEKLY_CREDITS * 100)
credits_remaining = max(0.0, WEEKLY_CREDITS - credits_used)
dollars_used = credits_used * CENTS_PER_CREDIT / 100
dollars_remaining = credits_remaining * CENTS_PER_CREDIT / 100
total_dollars = WEEKLY_CREDITS * CENTS_PER_CREDIT / 100

BLOCK = chr(9608)
DOT = chr(9617)

def bar(pct, length=25):
    f = int(length * pct / 100)
    b = BLOCK * f + DOT * (length - f)
    if pct >= 90:
        return chr(27) + '[91m' + b + chr(27) + '[0m'
    elif pct >= 70:
        return chr(27) + '[93m' + b + chr(27) + '[0m'
    return b

def fmt_date(d):
    try:
        return datetime.strptime(d, '%Y-%m-%d').strftime('%m-%d %a')
    except:
        return d

def spacer(n=1):
    for _ in range(n):
        print('')

cmd = ARGS[0] if ARGS else ''

if cmd == '--daily':
    print('Codex Credits ─ 每日明细 (滚动7天)')
    print(f'  窗口: {period_start_str} → {today_cst}')
    spacer()
    print(f'{"日期":<12}{"事件":<5}{"新鲜输入":<11}{"输出":<9}{"缓存":<11}{"Credits":<9}{"累计":<9}')
    print('-' * 66)
    cumul = 0.0
    for d in period_dates:
        v = daily[d]
        billable = v['fresh_input'] + v['output'] * OUTPUT_TOKEN_WEIGHT + v['cached'] * CACHED_TOKEN_WEIGHT
        cr = billable / TOKENS_PER_CREDIT
        cumul += cr
        print(f'{fmt_date(d):<12}{v["events"]:<5}{v["fresh_input"]:<11,}{v["output"]:<9,}{v["cached"]:<11,}{cr:<9.1f}{cumul:<9.1f}')
    spacer()
    print(f'  {bar(credits_pct)}  {credits_pct:.1f}%')
    print(f'  已用: {credits_used:.1f} / {WEEKLY_CREDITS} credits')

elif cmd == '--weekly':
    print('Codex Credits ─ 周明细')
    print(f'  窗口: {period_start_str} → {today_cst}')
    spacer()
    print(f'{"日期":<12}{"事件":<5}{"新鲜输入":<11}{"输出":<9}{"缓存":<11}{"Credits":<8}{"%":<6}')
    print('-' * 62)
    for d in period_dates:
        v = daily[d]
        billable = v['fresh_input'] + v['output'] * OUTPUT_TOKEN_WEIGHT + v['cached'] * CACHED_TOKEN_WEIGHT
        cr = billable / TOKENS_PER_CREDIT
        pct = cr / WEEKLY_CREDITS * 100
        print(f'{fmt_date(d):<12}{v["events"]:<5}{v["fresh_input"]:<11,}{v["output"]:<9,}{v["cached"]:<11,}{cr:<8.1f}{pct:<5.1f}%')
    spacer()
    print(f'  {bar(credits_pct)}  {credits_pct:.1f}%')
    print(f'  已用: {credits_used:.1f} / {WEEKLY_CREDITS} credits')
    print(f'  剩余: {credits_remaining:.1f} credits')
    print(f'  金额: ${dollars_used:.2f} / ${total_dollars:.2f}')
    if all_models:
        print(f'  模型: {", ".join(sorted(all_models)[:5])}')

elif cmd == '--set-budget':
    budget_now = float(os.environ.get('WEEKLY_BUDGET_DOLLARS', '0') or '0')
    amount = 0
    if len(ARGS) > 1:
        try: amount = float(ARGS[1])
        except: pass

    if amount > 0:
        config = {}
        if os.path.exists(CONFIG_FILE):
            with open(CONFIG_FILE) as f:
                try: config = json.load(f)
                except: pass
        config['weekly_budget_dollars'] = amount
        with open(CONFIG_FILE, 'w') as f:
            json.dump(config, f, indent=2)
        print(f'✅ 周预算 \${amount:.0f}')
        print(f'  codex --set-budget {amount:.0f}  已完成')
        print(f'  菜单栏交替: Codex \$X ↔ Codex N%')
        print(f'  🟢<40%  🟡<70%  🟠<90%  🔴≥90%')
    else:
        budget_now = float(os.environ.get('WEEKLY_BUDGET_DOLLARS', '0') or '0')
        if budget_now > 0:
            print(f'当前预算: \${budget_now:.0f}/周')
        print(f'用法: codex --set-budget 87')
        print(f'示例: codex --set-budget 75  (基础 \$75/周)')
        print(f'示例: codex --set-budget 87  (\$75+\$12/周)')

elif cmd in ('--set-reset', '--auto-detect'):
    now_cst_label = now_cst.strftime('%Y-%m-%d %H:%M CST')

    if cmd == '--set-reset':
        wd = os.environ.get('RESET_WEEKDAY', 'Wednesday')
        hr = int(os.environ.get('RESET_HOUR', 15))
        mn = int(os.environ.get('RESET_MINUTE', 16))
        print(f'Codex Credits 配置')
        spacer()
        print(f'当前重置: 每周 {wd} {hr:02d}:{mn:02d} CST')
        print()
        print(f'检测到首条消费，自动设为: {wd} {hr:02d}:{mn:02d} CST')
        print(f'如需调整，编辑 ~/.codex-credits.json')

    # 找计费起点：企业版免费期统一在 2026-05-27 结束
    # 从 5/27 之后找最早的一条 token_count 事件
    BILLING_START = datetime(2026, 5, 27, 12, 0, 0, tzinfo=CST)  # 下午 12:00，跳过免费期
    earliest_cst = None
    for f in all_files:
        try:
            with open(f) as fh:
                for line in fh:
                    parsed = json.loads(line)
                    if parsed.get('type') == 'event_msg':
                        pt = parsed.get('payload', {})
                        if isinstance(pt, dict) and pt.get('type') == 'token_count':
                            ts = parsed.get('timestamp', '')
                            if ts:
                                dt_utc = datetime.fromisoformat(ts.replace('Z', '+00:00'))
                                dt_cst = dt_utc.astimezone(CST)
                                if dt_cst >= BILLING_START:
                                    if earliest_cst is None or dt_cst < earliest_cst:
                                        earliest_cst = dt_cst
        except:
            pass

    if earliest_cst:
        WDAYS_CN = {'Monday': '周一','Tuesday': '周二','Wednesday': '周三','Thursday': '周四','Friday': '周五','Saturday': '周六','Sunday': '周日'}
        wd = earliest_cst.strftime('%A')
        hr = earliest_cst.hour
        mn = earliest_cst.minute
        date = earliest_cst.strftime('%Y-%m-%d')
        print()
        print(f'  🎯 首条消费: {date} {WDAYS_CN.get(wd,wd)} {hr:02d}:{mn:02d} CST')
        print(f'  每周重置: {WDAYS_CN.get(wd,wd)} {hr:02d}:{mn:02d} CST')
        print(f'  距今: {(now_cst - earliest_cst).days} 天')
        print()

    config = {
        'reset_weekday': wd if earliest_cst else (os.environ.get('RESET_WEEKDAY', 'Wednesday')),
        'reset_hour': hr if earliest_cst else int(os.environ.get('RESET_HOUR', 15)),
        'reset_minute': mn if earliest_cst else int(os.environ.get('RESET_MINUTE', 16)),
        'weekly_credits': WEEKLY_CREDITS,
        'tokens_per_credit': TOKENS_PER_CREDIT,
        'cents_per_credit': CENTS_PER_CREDIT,
        'output_token_weight': OUTPUT_TOKEN_WEIGHT,
        'cached_token_weight': CACHED_TOKEN_WEIGHT,
        'detected_from': earliest_cst.isoformat() if earliest_cst else None
    }
    with open(os.path.expanduser(CONFIG_FILE), 'w') as f:
        json.dump(config, f, indent=2)
    print(f'  Saved to {os.path.expanduser(CONFIG_FILE)}')

elif cmd == '--watch':
    import time
    print('Monitoring (5min interval)')
    print(f'  Window: {period_start_str} to {today_cst}')
    try:
        while True:
            total_fresh = 0
            total_output = 0
            total_cached = 0
            for f in all_files:
                try:
                    with open(f) as fh:
                        for line in fh:
                            parsed = json.loads(line)
                            if parsed.get('type') == 'event_msg':
                                info = parsed.get('payload', {}).get('info')
                                if info and isinstance(info, dict) and info.get('last_token_usage'):
                                    ts_utc = parsed.get('timestamp', '')
                                    dt_cst = datetime.fromisoformat(ts_utc.replace('Z', '+00:00')).astimezone(CST)
                                    if dt_cst >= period_start:
                                        ltu = info['last_token_usage']
                                        ti = ltu.get('input_tokens', 0) or 0
                                        ca = ltu.get('cached_input_tokens', 0) or 0
                                        ou = ltu.get('output_tokens', 0) or 0
                                        total_fresh += max(0, ti - ca)
                                        total_output += ou
                                        total_cached += ca
                except:
                    pass
            billable = total_fresh + total_output * OUTPUT_TOKEN_WEIGHT + total_cached * CACHED_TOKEN_WEIGHT
            cr = billable / TOKENS_PER_CREDIT
            pct = min(100.0, cr / WEEKLY_CREDITS * 100)
            now = datetime.now().strftime('%H:%M:%S')
            print(f'[{now}] {bar(pct, 25)} {pct:.1f}%  ({cr:.1f}/{WEEKLY_CREDITS} cr)')
            time.sleep(300)
    except KeyboardInterrupt:
        print()
        sys.exit(0)

elif cmd == '--status':
    # 单行状态 — 显示本周花费
    print(f'Codex \${dollars_used:.2f}')

elif cmd == '--oneline':
    # 详细单行 — 美金为主
    print(f'Codex: \${dollars_used:.2f} this week  (input {rolling["fresh_input"]:,} tokens)')

elif cmd == '--version':
    print('daily-usage.sh v2.0 - Codex Credits Tracker')
    print(f'Weekly limit: {WEEKLY_CREDITS} credits = ${total_dollars:.2f}')
    print(f'Unit rate: {TOKENS_PER_CREDIT} billable units/credit')
    print(f'Weights: fresh=1 output={OUTPUT_TOKEN_WEIGHT:g} cached={CACHED_TOKEN_WEIGHT:g}')
    print(f'Files scanned: {len(all_files)}')
    print(f'Days with data: {len(daily)}')
    print(f'Config: {CONFIG_FILE}')
    print(f'Models: {sorted(all_models) if all_models else "(none detected)"}')

elif cmd == '--debug':
    print(f'Rolling dates: {period_dates}')
    print(f'All dates: {sorted(daily.keys())}')
    print(f'Files: {len(all_files)}')
    print(f'Config: {CONFIG_FILE}')
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE) as f:
            print(f.read())

else:
    # 默认: 美金花费
    print()
    print(f'  Codex 本周: \033[1m\${dollars_used:.2f}\033[0m')
    spacer()
    print(f'  新鲜输入:  {rolling["fresh_input"]:,} tokens')
    print(f'  输出:      {rolling["output"]:,} tokens')
    print(f'  缓存:      {rolling["cached"]:,} tokens')
    if all_models:
        print(f'  模型:      {", ".join(sorted(all_models)[:5])}')
    spacer()
    print(f'  窗口: {period_start_str} ~ {today_cst}')
    if dollars_used < 0.01:
        print()
        print('  (本周尚无用量数据)')
PYEOF
