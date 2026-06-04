#!/bin/bash
# codex-credits-cache.sh — PostToolUse 钩子：更新 credits 缓存
# 按模型分别计价，使用 ccusage 公开价格 × 企业折扣系数

set -euo pipefail

CACHE_FILE="/tmp/codex-credits.json"
SESSION_DIR="$HOME/.codex/sessions"
LOCK_FILE="/tmp/codex-credits.lock"

[ -f "$LOCK_FILE" ] && [ "$(find "$LOCK_FILE" -mmin -1 2>/dev/null || true)" ] && exit 0
touch "$LOCK_FILE"

export SESSION_DIR CACHE_FILE

python3 <<'PYEOF'
import json, glob, os
from datetime import datetime, timedelta, timezone
from collections import defaultdict

SESSION_DIR = os.path.expanduser(os.environ['SESSION_DIR'])
CACHE_FILE = os.environ['CACHE_FILE']
CONFIG_FILE = os.path.expanduser('~/.codex-credits.json')
CST = timezone(timedelta(hours=8))

# ── ccusage 公开价 (per 1M tokens) ──
# 来源: https://github.com/ryoppippi/ccusage
MODEL_PRICES = {
    'gpt-5.5':            (5.00,  30.00),
    'gpt-5.4':            (2.50,  15.00),
    'gpt-5.4-mini':       (0.75,  4.50),
    'gpt-5':              (1.25,  10.00),
    'gpt-5.1':            (1.25,  10.00),
    'codex-auto-review':  (0.00,   0.00),
    'deepseek-v4-pro':    (5.00,  47.00),
    'deepseek-v4-flash':  (0.27,   0.19),
    'deepseek-v4':        (3.00,  20.00),
}
FALLBACK_PRICE = (3.00, 20.00)  # 未知模型默认

# ── 读取配置 ──
try:
    with open(CONFIG_FILE) as f: cfg = json.load(f)
except:
    cfg = {}

WEEKLY_CREDITS = cfg.get('weekly_credits', 1875)
CENTS_PER_CREDIT = cfg.get('cents_per_credit', 4)
RESET_WD  = cfg.get('reset_weekday', 'Wednesday')
RESET_HR  = cfg.get('reset_hour', 15)
RESET_MIN = cfg.get('reset_minute', 16)
CREDIT_COST = CENTS_PER_CREDIT / 100  # $0.04

# ── 重置窗口 ──
WEEKDAYS = ['Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday']
now_cst = datetime.now(CST)
reset_wd_num = WEEKDAYS.index(RESET_WD) if RESET_WD in WEEKDAYS else 2
days_since = (now_cst.weekday() - reset_wd_num) % 7
period_start = now_cst - timedelta(days=days_since)
period_start = period_start.replace(hour=RESET_HR, minute=RESET_MIN, second=0, microsecond=0)
if now_cst < period_start:
    period_start -= timedelta(days=7)

# ── 扫描所有 rollout 文件，按模型聚合 ──
all_files = sorted(glob.glob(os.path.join(SESSION_DIR, '2***', '*', '*', 'rollout-*.jsonl')))

per_model = defaultdict(lambda: {'fresh':0, 'output':0, 'cached':0})
events = 0

for f in all_files:
    try:
        with open(f) as fh:
            current_model = None
            for line in fh:
                parsed = json.loads(line)
                if parsed.get('type') == 'turn_context':
                    pl = parsed.get('payload', {})
                    if isinstance(pl, dict):
                        m = pl.get('model') or pl.get('model_name') or ''
                        if m: current_model = m
                if parsed.get('type') == 'event_msg':
                    pt = parsed.get('payload', {})
                    if isinstance(pt, dict) and pt.get('type') == 'token_count':
                        info = pt.get('info')
                        if info and isinstance(info, dict) and info.get('last_token_usage'):
                            ts = parsed.get('timestamp', '')
                            if ts:
                                dt = datetime.fromisoformat(ts.replace('Z', '+00:00')).astimezone(CST)
                                if dt >= period_start:
                                    ltu = info['last_token_usage']
                                    ti = ltu.get('input_tokens', 0) or 0
                                    ca = ltu.get('cached_input_tokens', 0) or 0
                                    ou = ltu.get('output_tokens', 0) or 0
                                    m = current_model or 'unknown'
                                    per_model[m]['fresh'] += max(0, ti - ca)
                                    per_model[m]['output'] += ou
                                    per_model[m]['cached'] += ca
                                    events += 1
    except: pass

# ── 按模型计算公开价成本 ──
total_public_dollars = 0
total_fresh = 0
total_output = 0
total_cached = 0
model_detail = {}

for m, s in per_model.items():
    p = MODEL_PRICES.get(m, FALLBACK_PRICE)
    cost = s['fresh'] / 1e6 * p[0] + s['output'] / 1e6 * p[1]
    total_public_dollars += cost
    total_fresh += s['fresh']
    total_output += s['output']
    total_cached += s['cached']
    model_detail[m] = {'fresh': s['fresh'], 'output': s['output'], 'cost': round(cost, 4)}

# ── 企业版 dollars = 公开价 × 折扣因子 ──
# 校准: 两个窗口反推 factor ≈ 2.0
#  窗口1: $75 / $33.59 = 2.23
#  窗口2: $12 / $6.50  = 1.85
factor = cfg.get('enterprise_price_factor', 2.0)

enterprise_dollars = round(total_public_dollars * factor, 2)

credits_used = round(enterprise_dollars / CREDIT_COST, 1)
budget = cfg.get('weekly_budget_dollars', 0)
credits_pct = round(min(100, enterprise_dollars / budget * 100), 1) if budget > 0 else 0
credits_remaining = round(max(0, budget / CREDIT_COST - credits_used), 1) if budget > 0 else 0

# ── 写入缓存 ──
cache = {
    'dollars_used': enterprise_dollars,
    'dollars_limit': budget,
    'credits_used': credits_used,
    'credits_limit': WEEKLY_CREDITS,
    'credits_pct': credits_pct,
    'credits_remaining': credits_remaining,
    'fresh_input': total_fresh,
    'output': total_output,
    'cached': total_cached,
    'public_dollars': round(total_public_dollars, 2),
    'enterprise_factor': factor,
    'events': events,
    'models': sorted(per_model.keys()),
    'model_detail': model_detail,
    'tokens_per_credit': cfg.get('tokens_per_credit', 3900),
    'updated_at': now_cst.isoformat(),
    'period_start': period_start.isoformat(),
    'period_end': (period_start + timedelta(days=7)).isoformat(),
}

with open(CACHE_FILE, 'w') as f:
    json.dump(cache, f, indent=2)

print(f'Codex credits cached: \${enterprise_dollars:.2f} (public: \${total_public_dollars:.2f})')
PYEOF

rm -f "$LOCK_FILE"
