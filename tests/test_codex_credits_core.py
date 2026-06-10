import json
import os
import tempfile
import unittest
from datetime import datetime
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


if __name__ == "__main__":
    unittest.main()
