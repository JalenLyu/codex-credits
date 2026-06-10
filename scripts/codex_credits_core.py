#!/usr/bin/env python3
import argparse
import json
import os
import sys
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Optional


CST = timezone(timedelta(hours=8))
WEEKDAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
DEFAULT_BILLING_START = datetime(2026, 5, 27, 12, 0, 0, tzinfo=CST)


@dataclass
class Config:
    weekly_credits: int = 1875
    tokens_per_credit: int = 3981
    cents_per_credit: int = 4
    output_token_weight: float = 0
    cached_token_weight: float = 0
    reset_weekday: str = "Wednesday"
    reset_hour: int = 15
    reset_minute: int = 16
    weekly_budget_dollars: float = 0
    detected_from: Optional[str] = None


def _as_int(value, fallback):
    try:
        return int(value)
    except (TypeError, ValueError):
        return fallback


def _as_float(value, fallback):
    try:
        return float(value)
    except (TypeError, ValueError):
        return fallback


def load_config(config_path=None):
    path = Path(os.path.expanduser(config_path or "~/.codex-credits.json"))
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        raw = {}

    return Config(
        weekly_credits=_as_int(raw.get("weekly_credits"), 1875),
        tokens_per_credit=_as_int(raw.get("tokens_per_credit"), 3981),
        cents_per_credit=_as_int(raw.get("cents_per_credit"), 4),
        output_token_weight=_as_float(raw.get("output_token_weight"), 0),
        cached_token_weight=_as_float(raw.get("cached_token_weight"), 0),
        reset_weekday=raw.get("reset_weekday") or "Wednesday",
        reset_hour=_as_int(raw.get("reset_hour"), 15),
        reset_minute=_as_int(raw.get("reset_minute"), 16),
        weekly_budget_dollars=_as_float(raw.get("weekly_budget_dollars"), 0),
        detected_from=raw.get("detected_from"),
    )


def read_config_dict(config_path=None):
    path = Path(os.path.expanduser(config_path or "~/.codex-credits.json"))
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
        return raw if isinstance(raw, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def write_config_dict(config, config_path=None):
    path = Path(os.path.expanduser(config_path or "~/.codex-credits.json"))
    path.write_text(json.dumps(config, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def discover_rollout_files(session_dir, archive_dir=None):
    session_root = Path(os.path.expanduser(str(session_dir)))
    files = list(session_root.glob("2*/*/*/rollout-*.jsonl"))
    if archive_dir:
        archive_root = Path(os.path.expanduser(str(archive_dir)))
        files.extend(archive_root.glob("rollout-*.jsonl"))
    return sorted(files)


def parse_timestamp(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00")).astimezone(CST)
    except ValueError:
        return None


def iter_token_events(session_dir, archive_dir=None):
    for file_path in discover_rollout_files(session_dir, archive_dir):
        current_model = None
        try:
            with file_path.open(encoding="utf-8") as fh:
                for line in fh:
                    try:
                        parsed = json.loads(line)
                    except json.JSONDecodeError:
                        continue

                    record_type = parsed.get("type")
                    if record_type == "turn_context":
                        payload = parsed.get("payload", {})
                        if isinstance(payload, dict):
                            model = payload.get("model") or payload.get("model_name")
                            if model:
                                current_model = str(model)
                        continue

                    if record_type != "event_msg":
                        continue

                    payload = parsed.get("payload", {})
                    if not isinstance(payload, dict) or payload.get("type") != "token_count":
                        continue

                    info = payload.get("info")
                    if not isinstance(info, dict) or not isinstance(info.get("last_token_usage"), dict):
                        continue

                    dt = parse_timestamp(parsed.get("timestamp"))
                    if dt is None:
                        continue

                    usage = info["last_token_usage"]
                    input_tokens = usage.get("input_tokens", 0) or 0
                    cached_tokens = usage.get("cached_input_tokens", 0) or 0
                    output_tokens = usage.get("output_tokens", 0) or 0

                    yield {
                        "timestamp": dt,
                        "fresh_input": max(0, input_tokens - cached_tokens),
                        "cached": max(0, cached_tokens),
                        "output": max(0, output_tokens),
                        "model": current_model or "unknown",
                    }
        except (OSError, UnicodeDecodeError):
            continue


def get_period_start(now, cfg):
    reset_wd_num = WEEKDAYS.index(cfg.reset_weekday) if cfg.reset_weekday in WEEKDAYS else 2
    days_since = (now.weekday() - reset_wd_num) % 7
    period_start = now - timedelta(days=days_since)
    period_start = period_start.replace(
        hour=cfg.reset_hour,
        minute=cfg.reset_minute,
        second=0,
        microsecond=0,
    )
    if now < period_start:
        period_start -= timedelta(days=7)
    return period_start


def billable_units(fresh_input, output, cached, cfg):
    return int(round(fresh_input + output * cfg.output_token_weight + cached * cfg.cached_token_weight))


def _round_money(value):
    return round(float(value) + 0, 2)


def _round_one(value):
    return round(float(value) + 0, 1)


def build_report(session_dir, archive_dir, cfg, now=None):
    now_cst = (now or datetime.now(CST)).astimezone(CST)
    period_start = get_period_start(now_cst, cfg)
    period_end = period_start + timedelta(days=7)
    active_end = min(now_cst, period_end)

    events = [
        event
        for event in iter_token_events(session_dir, archive_dir)
        if period_start <= event["timestamp"] <= active_end
    ]

    fresh_total = sum(event["fresh_input"] for event in events)
    output_total = sum(event["output"] for event in events)
    cached_total = sum(event["cached"] for event in events)
    units = billable_units(fresh_total, output_total, cached_total, cfg)

    credits_used_raw = units / cfg.tokens_per_credit if cfg.tokens_per_credit > 0 else 0
    dollars_used_raw = credits_used_raw * cfg.cents_per_credit / 100
    default_dollars_limit = cfg.weekly_credits * cfg.cents_per_credit / 100
    dollars_limit = cfg.weekly_budget_dollars if cfg.weekly_budget_dollars > 0 else default_dollars_limit
    credits_limit = dollars_limit / (cfg.cents_per_credit / 100) if cfg.cents_per_credit > 0 else cfg.weekly_credits
    credits_pct = min(100.0, credits_used_raw / credits_limit * 100) if credits_limit > 0 else 0

    model_totals = defaultdict(lambda: {"fresh_input": 0, "output": 0, "cached": 0, "events": 0})
    daily_totals = defaultdict(lambda: {"fresh_input": 0, "output": 0, "cached": 0, "events": 0, "models": set()})

    for event in events:
        model = event["model"]
        model_totals[model]["fresh_input"] += event["fresh_input"]
        model_totals[model]["output"] += event["output"]
        model_totals[model]["cached"] += event["cached"]
        model_totals[model]["events"] += 1

        day_key = event["timestamp"].strftime("%Y-%m-%d")
        daily_totals[day_key]["fresh_input"] += event["fresh_input"]
        daily_totals[day_key]["output"] += event["output"]
        daily_totals[day_key]["cached"] += event["cached"]
        daily_totals[day_key]["events"] += 1
        daily_totals[day_key]["models"].add(model)

    model_detail = {}
    for model, values in sorted(model_totals.items()):
        model_units = billable_units(values["fresh_input"], values["output"], values["cached"], cfg)
        model_credits = model_units / cfg.tokens_per_credit if cfg.tokens_per_credit > 0 else 0
        model_detail[model] = {
            "fresh_input": values["fresh_input"],
            "output": values["output"],
            "cached": values["cached"],
            "events": values["events"],
            "billable_units": model_units,
            "credits": _round_one(model_credits),
            "dollars": _round_money(model_credits * cfg.cents_per_credit / 100),
        }

    daily = []
    cumulative_credits = 0
    for day, values in sorted(daily_totals.items()):
        day_units = billable_units(values["fresh_input"], values["output"], values["cached"], cfg)
        day_credits = day_units / cfg.tokens_per_credit if cfg.tokens_per_credit > 0 else 0
        cumulative_credits += day_credits
        daily.append(
            {
                "date": day,
                "fresh_input": values["fresh_input"],
                "output": values["output"],
                "cached": values["cached"],
                "events": values["events"],
                "billable_units": day_units,
                "credits": _round_one(day_credits),
                "credits_pct": _round_one(day_credits / credits_limit * 100) if credits_limit > 0 else 0,
                "cumulative_credits": _round_one(cumulative_credits),
                "models": sorted(values["models"]),
            }
        )

    return {
        "dollars_used": _round_money(dollars_used_raw),
        "dollars_limit": _round_money(dollars_limit),
        "base_dollars_limit": _round_money(default_dollars_limit),
        "credits_used": _round_one(credits_used_raw),
        "credits_limit": _round_one(credits_limit),
        "weekly_credits": cfg.weekly_credits,
        "credits_pct": _round_one(credits_pct),
        "credits_remaining": _round_one(max(0, credits_limit - credits_used_raw)),
        "dollars_remaining": _round_money(max(0, dollars_limit - dollars_used_raw)),
        "fresh_input": fresh_total,
        "output": output_total,
        "cached": cached_total,
        "billable_units": units,
        "events": len(events),
        "models": sorted(model_totals.keys()),
        "model_detail": model_detail,
        "daily": daily,
        "tokens_per_credit": cfg.tokens_per_credit,
        "output_token_weight": cfg.output_token_weight,
        "cached_token_weight": cfg.cached_token_weight,
        "cents_per_credit": cfg.cents_per_credit,
        "weekly_budget_dollars": cfg.weekly_budget_dollars,
        "updated_at": now_cst.isoformat(),
        "period_start": period_start.isoformat(),
        "period_end": period_end.isoformat(),
        "period_active_end": active_end.isoformat(),
        "reset_weekday": cfg.reset_weekday,
        "reset_hour": cfg.reset_hour,
        "reset_minute": cfg.reset_minute,
        "detected_from": cfg.detected_from,
    }


def detect_first_usage(session_dir, archive_dir, after=DEFAULT_BILLING_START):
    first = None
    for event in iter_token_events(session_dir, archive_dir):
        dt = event["timestamp"]
        if dt >= after and (first is None or dt < first):
            first = dt
    return first


def calibrate_rate(cfg, billable_units, actual_dollars):
    credit_cost = cfg.cents_per_credit / 100
    if billable_units <= 0:
        raise ValueError("当前窗口没有可校准的 billable units")
    if actual_dollars <= 0 or credit_cost <= 0:
        raise ValueError("实际消耗金额必须大于 0")

    actual_credits = actual_dollars / credit_cost
    if actual_credits <= 0:
        raise ValueError("实际 credits 必须大于 0")

    return {
        "weekly_budget_dollars": cfg.weekly_budget_dollars,
        "weekly_credits": cfg.weekly_credits,
        "tokens_per_credit": max(1, int(round(billable_units / actual_credits))),
        "cents_per_credit": cfg.cents_per_credit,
        "output_token_weight": cfg.output_token_weight,
        "cached_token_weight": cfg.cached_token_weight,
        "reset_weekday": cfg.reset_weekday,
        "reset_hour": cfg.reset_hour,
        "reset_minute": cfg.reset_minute,
        "detected_from": cfg.detected_from,
    }


def format_token_count(value):
    value = int(value)
    if value >= 1_000_000:
        return f"{value / 1_000_000:.1f}M"
    if value >= 1_000:
        return f"{value / 1_000:.0f}K"
    return str(value)


def status_icon(pct):
    if pct >= 90:
        return "🔴"
    if pct >= 70:
        return "🟠"
    if pct >= 40:
        return "🟡"
    return "🟢"


def status_label(pct):
    if pct >= 90:
        return "额度即将用尽"
    if pct >= 70:
        return "用量偏高"
    if pct >= 40:
        return "用量中等"
    return "用量正常"


def progress_bar(pct, length=24, filled_char="█", empty_char="░"):
    filled = max(0, min(length, int(round(length * pct / 100))))
    return filled_char * filled + empty_char * (length - filled)


def fmt_date(day):
    try:
        return datetime.strptime(day, "%Y-%m-%d").strftime("%m-%d %a")
    except ValueError:
        return day


def default_paths():
    return {
        "session_dir": os.path.expanduser(os.environ.get("SESSION_DIR", "~/.codex/sessions")),
        "archive_dir": os.path.expanduser(os.environ.get("ARCHIVE_DIR", "~/.codex/archived_sessions")),
        "config_file": os.path.expanduser(os.environ.get("CONFIG_FILE", "~/.codex-credits.json")),
        "cache_file": os.path.expanduser(os.environ.get("CACHE_FILE", "/tmp/codex-credits.json")),
    }


def build_default_report():
    paths = default_paths()
    cfg = load_config(paths["config_file"])
    return build_report(paths["session_dir"], paths["archive_dir"], cfg), cfg, paths


def build_or_load_cached_report():
    paths = default_paths()
    cfg = load_config(paths["config_file"])
    cache_path = Path(paths["cache_file"])
    try:
        cached = json.loads(cache_path.read_text(encoding="utf-8"))
        if isinstance(cached, dict) and "billable_units" in cached and "dollars_used" in cached:
            period_end = parse_timestamp(cached.get("period_end"))
            if period_end is None or datetime.now(CST) <= period_end:
                return cached, cfg, paths
    except (OSError, json.JSONDecodeError):
        pass
    return build_report(paths["session_dir"], paths["archive_dir"], cfg), cfg, paths


def print_weekly(report):
    print("Codex Credits - 周明细")
    print(f"  窗口: {report['period_start'][:16]} -> {report['period_active_end'][:10]}")
    print()
    print(f"{'日期':<12}{'事件':<5}{'新鲜输入':<11}{'输出':<9}{'缓存':<11}{'Credits':<8}{'%':<6}")
    print("-" * 62)
    for row in report["daily"]:
        print(
            f"{fmt_date(row['date']):<12}"
            f"{row['events']:<5}"
            f"{row['fresh_input']:<11,}"
            f"{row['output']:<9,}"
            f"{row['cached']:<11,}"
            f"{row['credits']:<8.1f}"
            f"{row['credits_pct']:<5.1f}%"
        )
    print()
    print(f"  {progress_bar(report['credits_pct'])}  {report['credits_pct']:.1f}%")
    print(f"  已用: {report['credits_used']:.1f} / {report['credits_limit']:.1f} credits")
    print(f"  剩余: {report['credits_remaining']:.1f} credits")
    print(f"  金额: ${report['dollars_used']:.2f} / ${report['dollars_limit']:.2f}")
    if report["models"]:
        print(f"  模型: {', '.join(report['models'][:5])}")


def print_daily(report):
    print("Codex Credits - 每日明细")
    print(f"  窗口: {report['period_start'][:16]} -> {report['period_active_end'][:10]}")
    print()
    print(f"{'日期':<12}{'事件':<5}{'新鲜输入':<11}{'输出':<9}{'缓存':<11}{'Credits':<9}{'累计':<9}")
    print("-" * 66)
    for row in report["daily"]:
        print(
            f"{fmt_date(row['date']):<12}"
            f"{row['events']:<5}"
            f"{row['fresh_input']:<11,}"
            f"{row['output']:<9,}"
            f"{row['cached']:<11,}"
            f"{row['credits']:<9.1f}"
            f"{row['cumulative_credits']:<9.1f}"
        )
    print()
    print(f"  {progress_bar(report['credits_pct'])}  {report['credits_pct']:.1f}%")
    print(f"  已用: {report['credits_used']:.1f} / {report['credits_limit']:.1f} credits")


def print_summary(report):
    print()
    print(f"  Codex 本周: \033[1m${report['dollars_used']:.2f}\033[0m")
    print()
    print(f"  新鲜输入:  {report['fresh_input']:,} tokens")
    print(f"  输出:      {report['output']:,} tokens")
    print(f"  缓存:      {report['cached']:,} tokens")
    print(f"  Billable:  {report['billable_units']:,} units")
    if report["models"]:
        print(f"  模型:      {', '.join(report['models'][:5])}")
    print()
    print(f"  窗口: {report['period_start'][:16]} ~ {report['period_active_end'][:10]}")
    print(f"  额度: ${report['dollars_used']:.2f} / ${report['dollars_limit']:.2f} ({report['credits_pct']:.1f}%)")
    if report["dollars_used"] < 0.01:
        print()
        print("  (本周尚无用量数据)")


def print_version(report, cfg, paths):
    print("daily-usage.sh v3.0 - Codex Credits Tracker")
    print(f"Weekly limit: {report['credits_limit']:.1f} credits = ${report['dollars_limit']:.2f}")
    print(f"Unit rate: {cfg.tokens_per_credit} billable units/credit")
    print(f"Weights: fresh=1 output={cfg.output_token_weight:g} cached={cfg.cached_token_weight:g}")
    print(f"Config: {paths['config_file']}")
    print(f"Models: {report['models'] if report['models'] else '(none detected)'}")


def save_cache(report, cache_file):
    Path(cache_file).write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def cmd_cache(_args):
    report, _cfg, paths = build_default_report()
    save_cache(report, paths["cache_file"])
    print(f"Codex credits cached: ${report['dollars_used']:.2f} ({report['billable_units']:,} units)")
    return 0


def cmd_barrage(_args):
    report, _cfg, _paths = build_or_load_cached_report()
    icon = status_icon(report["credits_pct"])
    payload = {
        "title": f"{icon} Codex 本周",
        "subtitle": f"{status_label(report['credits_pct'])} · ${report['dollars_used']:.2f} / ${report['dollars_limit']:.2f}",
        "body": (
            f"输入 {format_token_count(report['fresh_input'])} · "
            f"输出 {format_token_count(report['output'])} · "
            f"剩余 ${report['dollars_remaining']:.2f}"
        ),
    }
    print(json.dumps(payload, ensure_ascii=False))
    return 0


def cmd_menu(_args):
    report, _cfg, _paths = build_or_load_cached_report()
    icon = status_icon(report["credits_pct"])
    tick = int(datetime.now().timestamp()) // 5
    if tick % 2:
        title = f"{icon} Codex {int(round(report['credits_pct']))}%"
    else:
        title = f"{icon} Codex ${report['dollars_used']:.0f}"

    if report["credits_pct"] >= 90:
        title += " | color=red"
    elif report["credits_pct"] >= 70:
        title += " | color=orange"

    script_dir = os.environ.get("SCRIPT_DIR", str(Path(__file__).resolve().parent))
    cache_script = str(Path(script_dir) / "codex-credits-cache.sh")
    main_script = str(Path(script_dir) / "daily-usage.sh")

    print(title)
    print("---")
    print("Overview | color=#6B7280")
    print(f"{icon} {status_label(report['credits_pct'])}")
    print(f"{progress_bar(report['credits_pct'], 12, '█', '□')}  {report['credits_pct']:.1f}%")
    print(f"${report['dollars_used']:.2f} / ${report['dollars_limit']:.2f} · 剩余 ${report['dollars_remaining']:.2f}")
    print("---")
    print("Usage | color=#6B7280")
    print(f"输入 {format_token_count(report['fresh_input'])} · 输出 {format_token_count(report['output'])}")
    print(f"缓存 {format_token_count(report['cached'])} · Billable {format_token_count(report['billable_units'])}")
    model_str = ", ".join(report["models"][:3]) if report["models"] else "无模型记录"
    print(f"模型 {model_str}")
    print("---")
    print("Billing Window | color=#6B7280")
    print(f"{report['period_start'][:10]} {report['period_start'][11:16]} -> {report['period_end'][:10]} {report['period_end'][11:16]}")
    print(f"刷新 {report['updated_at'][11:19]} · {report['events']} 次调用")
    print("---")
    print("Calibration | color=#6B7280")
    print(f"起点 {report['reset_weekday']} {report['reset_hour']:02d}:{report['reset_minute']:02d}")
    print(f"单价 {report['tokens_per_credit']:,} units/credit")
    print(f"权重 output={report['output_token_weight']:g} cached={report['cached_token_weight']:g}")
    print(f"🧭 校准起点 | bash={main_script} param1=--calibrate-start terminal=true")
    print(f"💱 校准单价 | bash={main_script} param1=--calibrate-rate terminal=true")
    print(f"⚙️ 完整校准 | bash={main_script} param1=--calibrate terminal=true")
    print("---")
    print(f"🔄 刷新数据 | bash={cache_script} terminal=false refresh=true")
    print(f"📋 周明细 | bash={main_script} param1=--weekly terminal=true")
    print(f"💵 设置预算 | bash={main_script} param1=--set-budget terminal=true")
    return 0


def apply_start_calibration(config_path, first_usage):
    raw = read_config_dict(config_path)
    raw["reset_weekday"] = first_usage.strftime("%A")
    raw["reset_hour"] = first_usage.hour
    raw["reset_minute"] = first_usage.minute
    raw["detected_from"] = first_usage.isoformat()
    raw.setdefault("weekly_credits", 1875)
    raw.setdefault("tokens_per_credit", 3981)
    raw.setdefault("cents_per_credit", 4)
    raw.setdefault("output_token_weight", 0)
    raw.setdefault("cached_token_weight", 0)
    raw.setdefault("weekly_budget_dollars", 0)
    write_config_dict(raw, config_path)
    return raw


def parse_local_datetime(value):
    normalized = value.strip().replace("T", " ")
    for fmt in ("%Y-%m-%d %H:%M", "%Y-%m-%d %H:%M:%S"):
        try:
            return datetime.strptime(normalized, fmt).replace(tzinfo=CST)
        except ValueError:
            pass
    parsed = parse_timestamp(value)
    if parsed:
        return parsed
    raise ValueError("时间格式请使用 YYYY-MM-DD HH:MM")


def cmd_calibrate_start(args):
    paths = default_paths()
    if args.value:
        first = parse_local_datetime(args.value)
    else:
        first = detect_first_usage(paths["session_dir"], paths["archive_dir"], after=DEFAULT_BILLING_START)
        if first is None:
            print("未找到可用于校准的 token_count 记录")
            return 1

    apply_start_calibration(paths["config_file"], first)
    print(f"✅ 起点已校准: {first.strftime('%Y-%m-%d %A %H:%M')} CST")
    print(f"  Saved to {paths['config_file']}")
    return 0


def cmd_calibrate_rate(args):
    report, cfg, paths = build_default_report()
    actual = args.actual_dollars
    if actual is None:
        if sys.stdin.isatty():
            default = cfg.weekly_budget_dollars if cfg.weekly_budget_dollars > 0 else report["base_dollars_limit"]
            entered = input(f"本窗口实际消耗金额（默认 ${default:.2f}）: ").strip()
            actual = float(entered) if entered else default
        else:
            actual = cfg.weekly_budget_dollars if cfg.weekly_budget_dollars > 0 else report["base_dollars_limit"]

    updated = calibrate_rate(cfg, report["billable_units"], float(actual))
    raw = read_config_dict(paths["config_file"])
    raw.update(updated)
    write_config_dict(raw, paths["config_file"])
    print(f"✅ 单价已校准: {updated['tokens_per_credit']:,} billable units/credit")
    print(f"  基于当前窗口 {report['billable_units']:,} units = ${float(actual):.2f}")
    print(f"  Saved to {paths['config_file']}")
    return 0


def cmd_set_budget(args):
    paths = default_paths()
    if args.amount is None:
        cfg = load_config(paths["config_file"])
        if sys.stdin.isatty():
            current = f"${cfg.weekly_budget_dollars:.0f}" if cfg.weekly_budget_dollars > 0 else "未设置"
            entered = input(f"周预算金额（当前 {current}，回车取消）: ").strip()
            if not entered:
                print("未修改预算")
                return 0
            args.amount = float(entered)
        else:
            if cfg.weekly_budget_dollars > 0:
                print(f"当前预算: ${cfg.weekly_budget_dollars:.0f}/周")
            print("用法: codex --set-budget 87")
            print("示例: codex --set-budget 75")
            print("示例: codex --set-budget 87")
            return 0

    raw = read_config_dict(paths["config_file"])
    raw["weekly_budget_dollars"] = float(args.amount)
    raw.setdefault("weekly_credits", 1875)
    raw.setdefault("tokens_per_credit", 3981)
    raw.setdefault("cents_per_credit", 4)
    raw.setdefault("output_token_weight", 0)
    raw.setdefault("cached_token_weight", 0)
    write_config_dict(raw, paths["config_file"])
    print(f"✅ 周预算 ${float(args.amount):.0f}")
    print("  🟢<40%  🟡<70%  🟠<90%  🔴≥90%")
    return 0


def cmd_calibrate(_args):
    paths = default_paths()
    print("Codex Credits 校准")
    print()

    first = detect_first_usage(paths["session_dir"], paths["archive_dir"], after=DEFAULT_BILLING_START)
    if first:
        answer = input(f"使用首条消费作为起点？{first.strftime('%Y-%m-%d %A %H:%M')} CST [Y/n]: ").strip().lower()
        if answer in ("", "y", "yes"):
            apply_start_calibration(paths["config_file"], first)
            print("  起点已保存")

    cfg = load_config(paths["config_file"])
    budget_default = cfg.weekly_budget_dollars if cfg.weekly_budget_dollars > 0 else cfg.weekly_credits * cfg.cents_per_credit / 100
    budget = input(f"周预算金额（默认 ${budget_default:.2f}，回车保留）: ").strip()
    if budget:
        cmd_set_budget(argparse.Namespace(amount=float(budget)))

    report, cfg, _paths = build_default_report()
    actual = input("当前窗口实际消耗金额（回车跳过单价校准）: ").strip()
    if actual:
        updated = calibrate_rate(cfg, report["billable_units"], float(actual))
        raw = read_config_dict(paths["config_file"])
        raw.update(updated)
        write_config_dict(raw, paths["config_file"])
        print(f"  单价已保存: {updated['tokens_per_credit']:,} units/credit")

    print()
    print(f"✅ 校准完成: {paths['config_file']}")
    return 0


def cmd_report(args):
    command = args.command
    if command == "--watch":
        import time

        print("Monitoring (5min interval)")
        try:
            while True:
                report, _cfg, _paths = build_default_report()
                print(
                    f"[{datetime.now().strftime('%H:%M:%S')}] "
                    f"{progress_bar(report['credits_pct'])} {report['credits_pct']:.1f}% "
                    f"({report['credits_used']:.1f}/{report['credits_limit']:.1f} cr)"
                )
                time.sleep(300)
        except KeyboardInterrupt:
            print()
            return 0

    report, cfg, paths = build_default_report()
    if command == "--weekly":
        print_weekly(report)
    elif command == "--daily":
        print_daily(report)
    elif command == "--status":
        print(f"Codex ${report['dollars_used']:.2f}")
    elif command == "--oneline":
        print(f"Codex: ${report['dollars_used']:.2f} this week  (input {report['fresh_input']:,} tokens)")
    elif command == "--version":
        print_version(report, cfg, paths)
    elif command == "--debug":
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        print_summary(report)
    return 0


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)

    if not argv or argv[0].startswith("--"):
        command = argv[0] if argv else ""
        if command == "--set-budget":
            amount = float(argv[1]) if len(argv) > 1 else None
            return cmd_set_budget(argparse.Namespace(amount=amount))
        if command in ("--set-reset", "--auto-detect", "--calibrate-start"):
            value = " ".join(argv[1:]) if len(argv) > 1 else None
            return cmd_calibrate_start(argparse.Namespace(value=value))
        if command == "--calibrate-rate":
            actual = float(argv[1]) if len(argv) > 1 else None
            return cmd_calibrate_rate(argparse.Namespace(actual_dollars=actual))
        if command == "--calibrate":
            return cmd_calibrate(argparse.Namespace())
        return cmd_report(argparse.Namespace(command=command))

    parser = argparse.ArgumentParser()
    subcommands = parser.add_subparsers(dest="subcommand", required=True)
    subcommands.add_parser("cache").set_defaults(func=cmd_cache)
    subcommands.add_parser("menu").set_defaults(func=cmd_menu)
    subcommands.add_parser("barrage").set_defaults(func=cmd_barrage)
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
