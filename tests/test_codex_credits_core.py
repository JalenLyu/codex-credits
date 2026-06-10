import json
import os
import tempfile
import unittest
from contextlib import redirect_stdout
from datetime import datetime
from io import StringIO
from pathlib import Path

from scripts import codex_credits_core as core


CST = core.CST


def write_rollout(root, rel_path, records):
    path = root / rel_path
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as fh:
        for record in records:
            fh.write(json.dumps(record) + "\n")
    return path


def token_event(ts, input_tokens, cached_input_tokens=0, output_tokens=0):
    return {
        "type": "event_msg",
        "timestamp": ts,
        "payload": {
            "type": "token_count",
            "info": {
                "last_token_usage": {
                    "input_tokens": input_tokens,
                    "cached_input_tokens": cached_input_tokens,
                    "output_tokens": output_tokens,
                }
            },
        },
    }


class CodexCreditsCoreTest(unittest.TestCase):
    def test_billable_units_use_configured_weights(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            sessions = tmp_path / "sessions"
            archive = tmp_path / "archive"
            write_rollout(
                sessions,
                "2026/06/10/rollout-test.jsonl",
                [
                    {"type": "turn_context", "payload": {"model": "gpt-5.5"}},
                    token_event("2026-06-10T15:15:59+08:00", 9999, 0, 9999),
                    token_event("2026-06-10T15:16:00+08:00", 1000, 200, 50),
                ],
            )

            cfg = core.Config(
                tokens_per_credit=100,
                cents_per_credit=4,
                output_token_weight=2,
                cached_token_weight=0.5,
                reset_weekday="Wednesday",
                reset_hour=15,
                reset_minute=16,
                weekly_credits=250,
                weekly_budget_dollars=10,
            )
            report = core.build_report(
                sessions,
                archive,
                cfg,
                now=datetime(2026, 6, 10, 16, 0, tzinfo=CST),
            )

            self.assertEqual(report["fresh_input"], 800)
            self.assertEqual(report["output"], 50)
            self.assertEqual(report["cached"], 200)
            self.assertEqual(report["billable_units"], 1000)
            self.assertEqual(report["credits_used"], 10)
            self.assertEqual(report["dollars_used"], 0.4)
            self.assertEqual(report["credits_pct"], 4)
            self.assertEqual(report["models"], ["gpt-5.5"])

    def test_daily_rows_respect_reset_time_on_reset_day(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            sessions = tmp_path / "sessions"
            archive = tmp_path / "archive"
            write_rollout(
                sessions,
                "2026/06/10/rollout-test.jsonl",
                [
                    token_event("2026-06-10T15:15:59+08:00", 1000),
                    token_event("2026-06-10T15:16:00+08:00", 400),
                ],
            )

            cfg = core.Config(
                tokens_per_credit=100,
                reset_weekday="Wednesday",
                reset_hour=15,
                reset_minute=16,
            )
            report = core.build_report(
                sessions,
                archive,
                cfg,
                now=datetime(2026, 6, 10, 16, 0, tzinfo=CST),
            )

            self.assertEqual(report["period_start"], "2026-06-10T15:16:00+08:00")
            self.assertEqual(report["daily"][0]["date"], "2026-06-10")
            self.assertEqual(report["daily"][0]["fresh_input"], 400)
            self.assertEqual(report["daily"][0]["credits"], 4)

    def test_detect_first_usage_ignores_events_before_billing_start(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            sessions = tmp_path / "sessions"
            archive = tmp_path / "archive"
            write_rollout(
                sessions,
                "2026/05/27/rollout-test.jsonl",
                [
                    token_event("2026-05-27T11:59:59+08:00", 1000),
                    token_event("2026-05-27T15:16:00+08:00", 2000),
                ],
            )

            first = core.detect_first_usage(
                sessions,
                archive,
                after=datetime(2026, 5, 27, 12, 0, tzinfo=CST),
            )

            self.assertEqual(first.isoformat(), "2026-05-27T15:16:00+08:00")

    def test_rate_calibration_preserves_config_and_sets_tokens_per_credit(self):
        cfg = core.Config(
            weekly_budget_dollars=87,
            tokens_per_credit=3900,
            cents_per_credit=4,
            reset_weekday="Wednesday",
            reset_hour=15,
            reset_minute=16,
        )

        updated = core.calibrate_rate(cfg, billable_units=7464314, actual_dollars=75)

        self.assertEqual(updated["weekly_budget_dollars"], 87)
        self.assertEqual(updated["cents_per_credit"], 4)
        self.assertEqual(updated["tokens_per_credit"], 3981)

    def test_limit_recovery_calibration_uses_previous_seven_day_window(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            sessions = tmp_path / "sessions"
            archive = tmp_path / "archive"
            write_rollout(
                sessions,
                "2026/06/03/rollout-start.jsonl",
                [token_event("2026-06-03T15:15:59+08:00", 9999)],
            )
            write_rollout(
                sessions,
                "2026/06/10/rollout-end.jsonl",
                [
                    token_event("2026-06-03T15:16:00+08:00", 3981),
                    token_event("2026-06-10T15:15:59+08:00", 3981),
                    token_event("2026-06-10T15:16:00+08:00", 9999),
                ],
            )

            cfg = core.Config(cents_per_credit=4, weekly_budget_dollars=75)
            result = core.calibrate_from_limit_recovery(
                sessions,
                archive,
                cfg,
                recovery_time=datetime(2026, 6, 10, 15, 16, tzinfo=CST),
                limit_dollars=75,
            )

            self.assertEqual(result["window_start"], "2026-06-03T15:16:00+08:00")
            self.assertEqual(result["window_end"], "2026-06-10T15:16:00+08:00")
            self.assertEqual(result["billable_units"], 7962)
            self.assertEqual(result["tokens_per_credit"], 4)
            self.assertEqual(result["reset_weekday"], "Wednesday")
            self.assertEqual(result["reset_hour"], 15)
            self.assertEqual(result["reset_minute"], 16)

    def test_default_weekly_budget_is_75(self):
        self.assertEqual(core.Config().weekly_budget_dollars, 75)

    def test_calibrate_command_guides_limit_window_and_quota(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            sessions = tmp_path / "sessions"
            archive = tmp_path / "archive"
            config_file = tmp_path / "config.json"
            write_rollout(
                sessions,
                "2026/06/10/rollout-test.jsonl",
                [token_event("2026-06-03T15:16:00+08:00", 3981)],
            )
            config_file.write_text(
                json.dumps(
                    {
                        "tokens_per_credit": 3981,
                        "cents_per_credit": 4,
                        "weekly_budget_dollars": 75,
                    }
                ),
                encoding="utf-8",
            )
            old_env = os.environ.copy()
            try:
                os.environ.update(
                    {
                        "SESSION_DIR": str(sessions),
                        "ARCHIVE_DIR": str(archive),
                        "CONFIG_FILE": str(config_file),
                        "CACHE_FILE": str(tmp_path / "cache.json"),
                    }
                )
                result = core.run_limit_window_calibration(
                    recovery_time=datetime(2026, 6, 10, 15, 16, tzinfo=CST),
                    limit_dollars=75,
                )
            finally:
                os.environ.clear()
                os.environ.update(old_env)

            config = json.loads(config_file.read_text(encoding="utf-8"))
            self.assertEqual(result["window_start"], "2026-06-03T15:16:00+08:00")
            self.assertEqual(config["weekly_budget_dollars"], 75)
            self.assertEqual(config["tokens_per_credit"], 2)
            self.assertEqual(config["reset_weekday"], "Wednesday")
            self.assertEqual(config["reset_hour"], 15)
            self.assertEqual(config["reset_minute"], 16)

    def test_cached_report_is_ignored_after_period_end(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            sessions = tmp_path / "sessions"
            archive = tmp_path / "archive"
            config_file = tmp_path / "config.json"
            cache_file = tmp_path / "cache.json"

            write_rollout(
                sessions,
                "2026/06/10/rollout-test.jsonl",
                [token_event("2026-06-10T10:00:00+08:00", 1000)],
            )
            config_file.write_text(
                json.dumps(
                    {
                        "tokens_per_credit": 100,
                        "cents_per_credit": 4,
                        "reset_weekday": "Wednesday",
                        "reset_hour": 15,
                        "reset_minute": 16,
                        "weekly_budget_dollars": 10,
                    }
                ),
                encoding="utf-8",
            )
            cache_file.write_text(
                json.dumps(
                    {
                        "billable_units": 1,
                        "dollars_used": 99,
                        "period_end": "2026-01-01T00:00:00+08:00",
                    }
                ),
                encoding="utf-8",
            )

            old_env = os.environ.copy()
            try:
                os.environ.update(
                    {
                        "SESSION_DIR": str(sessions),
                        "ARCHIVE_DIR": str(archive),
                        "CONFIG_FILE": str(config_file),
                        "CACHE_FILE": str(cache_file),
                    }
                )
                report, _cfg, _paths = core.build_or_load_cached_report()
            finally:
                os.environ.clear()
                os.environ.update(old_env)

            self.assertEqual(report["billable_units"], 1000)
            self.assertEqual(report["dollars_used"], 0.4)

    def test_menu_explains_calibration_before_single_action(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            cache_file = tmp_path / "cache.json"
            cache_file.write_text(
                json.dumps(
                    {
                        "billable_units": 1000,
                        "dollars_used": 1,
                        "dollars_limit": 75,
                        "dollars_remaining": 74,
                        "credits_pct": 1.3,
                        "fresh_input": 1000,
                        "output": 0,
                        "cached": 0,
                        "models": [],
                        "period_start": "2026-06-03T15:16:00+08:00",
                        "period_end": "2099-06-10T15:16:00+08:00",
                        "updated_at": "2026-06-10T10:00:00+08:00",
                        "events": 1,
                        "reset_weekday": "Wednesday",
                        "reset_hour": 15,
                        "reset_minute": 16,
                        "tokens_per_credit": 3981,
                        "output_token_weight": 0,
                        "cached_token_weight": 0,
                    }
                ),
                encoding="utf-8",
            )

            old_env = os.environ.copy()
            try:
                os.environ.update({"CACHE_FILE": str(cache_file), "SCRIPT_DIR": "/tmp/scripts"})
                output = StringIO()
                with redirect_stdout(output):
                    core.cmd_menu(None)
            finally:
                os.environ.clear()
                os.environ.update(old_env)

            menu = output.getvalue()
            self.assertIn("达到限额后使用", menu)
            self.assertIn("恢复时间往前 7 天", menu)
            self.assertIn("限额后时间窗口和额度校准", menu)
            self.assertIn("计费事件", menu)
            self.assertNotIn("次调用", menu)
            self.assertNotIn("仅校准起点", menu)
            self.assertNotIn("仅校准单价", menu)

    def test_weekly_report_labels_events_as_billing_events(self):
        report = {
            "period_start": "2026-06-03T15:16:00+08:00",
            "period_active_end": "2026-06-10T15:16:00+08:00",
            "daily": [
                {
                    "date": "2026-06-10",
                    "events": 2,
                    "fresh_input": 100,
                    "output": 10,
                    "cached": 0,
                    "credits": 1.0,
                    "credits_pct": 0.1,
                }
            ],
            "credits_pct": 0.1,
            "credits_used": 1.0,
            "credits_limit": 1875.0,
            "credits_remaining": 1874.0,
            "dollars_used": 0.04,
            "dollars_limit": 75.0,
            "models": [],
        }

        output = StringIO()
        with redirect_stdout(output):
            core.print_weekly(report)

        weekly = output.getvalue()
        self.assertIn("计费事件", weekly)
        self.assertNotIn("日期          事件", weekly)


if __name__ == "__main__":
    unittest.main()
