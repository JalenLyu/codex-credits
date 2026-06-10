import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def make_fake_bin(root):
    bin_dir = root / "bin"
    bin_dir.mkdir()
    for name in ("defaults", "open"):
        path = bin_dir / name
        path.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        path.chmod(0o755)
    return bin_dir


def run_install(home, extra_env=None):
    fake_bin = make_fake_bin(home)
    env = os.environ.copy()
    env.update(
        {
            "HOME": str(home),
            "PATH": f"{fake_bin}:{env.get('PATH', '')}",
            "CACHE_FILE": str(home / "cache.json"),
            "SESSION_DIR": str(home / ".codex" / "sessions"),
            "ARCHIVE_DIR": str(home / ".codex" / "archived_sessions"),
        }
    )
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        ["bash", "install.sh"],
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


class InstallTest(unittest.TestCase):
    def test_fresh_install_creates_files_and_prints_swiftbar_guidance(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)

            result = run_install(home)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((home / ".codex-credits.json").is_file())
            self.assertTrue((home / ".codex" / "hooks.json").is_file())
            self.assertTrue((home / ".zshrc").is_file())
            self.assertTrue((home / "Library" / "SwiftBar" / "plugins" / "codex.10s.sh").is_symlink())
            config = json.loads((home / ".codex-credits.json").read_text(encoding="utf-8"))
            self.assertEqual(config["weekly_budget_dollars"], 75)
            self.assertIn("alias codex=", (home / ".zshrc").read_text(encoding="utf-8"))
            self.assertIn("PostToolUse", (home / ".codex" / "hooks.json").read_text(encoding="utf-8"))
            self.assertIn("菜单栏显示", result.stdout)
            self.assertIn("SwiftBar", result.stdout)

    def test_install_preserves_existing_calibration(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            existing = {
                "weekly_budget_dollars": 87,
                "tokens_per_credit": 1234,
                "reset_weekday": "Wednesday",
                "reset_hour": 9,
                "reset_minute": 30,
            }
            (home / ".codex-credits.json").write_text(json.dumps(existing), encoding="utf-8")

            result = run_install(home)

            self.assertEqual(result.returncode, 0, result.stderr)
            config = json.loads((home / ".codex-credits.json").read_text(encoding="utf-8"))
            self.assertEqual(config["weekly_budget_dollars"], 87)
            self.assertEqual(config["tokens_per_credit"], 1234)
            self.assertEqual(config["reset_weekday"], "Wednesday")
            self.assertEqual(config["reset_hour"], 9)
            self.assertEqual(config["reset_minute"], 30)


if __name__ == "__main__":
    unittest.main()
