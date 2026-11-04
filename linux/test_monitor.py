import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from monitor import Monitor, Session, read_session, reduce_record, render, safe_text


def record(kind, **payload):
    return json.dumps({"type": kind, "payload": payload}).encode() + b"\n"


def event(kind, **payload):
    return record("event_msg", type=kind, **payload)


class MonitorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.path = self.root / "rollout-test.jsonl"
        self.header = record("session_meta", id="test-session", cwd="/projects/deck", source="cli")
        self.path.write_bytes(self.header)

    def test_completed_turn_and_usage(self):
        self.path.write_bytes(self.header + record("turn_context", model="test-model")
                              + event("task_started") + event("token_count", info={
                                  "total_token_usage": {"total_tokens": 1234}},
                                  rate_limits={"primary": {"used_percent": 42}})
                              + event("task_complete", error=None))
        row = read_session(self.path)
        self.assertEqual((row.state, row.project, row.model), ("completed", "/projects/deck", "test-model"))
        self.assertEqual((row.total_tokens, row.limit_used_percent), (1234, 42))

    def test_interrupted_and_error_states(self):
        for data, expected in [(event("turn_aborted"), "interrupted"),
                               (event("task_complete", error={"message": "failed"}), "error")]:
            with self.subTest(expected=expected):
                self.path.write_bytes(self.header + event("task_started") + data)
                self.assertEqual(read_session(self.path).state, expected)

    def test_partial_write_waits_until_record_complete(self):
        complete = event("task_complete")
        self.path.write_bytes(self.header + event("task_started") + complete[:-3])
        monitor = Monitor(self.root)
        self.assertEqual(monitor.snapshot()[0].state, "working")
        with self.path.open("ab") as stream:
            stream.write(complete[-3:])
        self.assertEqual(monitor.snapshot()[0].state, "completed")

    def test_invalid_unknown_and_non_object_records_are_ignored(self):
        self.path.write_bytes(self.header + b"broken\n[]\nnull\n\xff\n"
                              + record("event_msg", type="future_event")
                              + b'{"type":"event_msg","payload":[]}\n')
        self.assertEqual(read_session(self.path).state, "unknown")

    def test_stale_is_independent_of_state_and_cached_data(self):
        self.path.write_bytes(self.header + event("task_started"))
        os.utime(self.path, (1000, 1000))
        monitor = Monitor(self.root)
        fresh = monitor.snapshot(now=1010)[0]
        stale = monitor.snapshot(now=1200)[0]
        self.assertEqual(stale.state, "working")
        self.assertFalse(fresh.stale)
        self.assertTrue(stale.stale)
        self.assertIn("working (stale)", render([stale], [], now=1200))

    def test_cache_avoids_rereading_unchanged_files(self):
        monitor = Monitor(self.root)
        monitor.snapshot()
        with patch("monitor.read_session", side_effect=AssertionError("unexpected read")):
            self.assertEqual(len(monitor.snapshot()), 1)

    def test_replaced_truncated_and_deleted_files(self):
        monitor = Monitor(self.root)
        self.path.write_bytes(self.header + event("task_started"))
        self.assertEqual(monitor.snapshot()[0].state, "working")
        replacement = self.root / "replacement"
        replacement.write_bytes(record("session_meta", id="replacement", cwd="/other"))
        replacement.replace(self.path)
        self.assertEqual(monitor.snapshot()[0].id, "replacement")
        self.path.write_bytes(b"")
        self.assertEqual(monitor.snapshot(), [])
        self.path.unlink()
        self.assertEqual(monitor.snapshot(), [])
        self.assertEqual(monitor.cache, {})

    def test_subagents_are_optional(self):
        child = self.root / "child.jsonl"
        child.write_bytes(record("session_meta", id="child", parent_thread_id="parent"))
        monitor = Monitor(self.root)
        self.assertEqual(len(monitor.snapshot()), 1)
        self.assertEqual(len(monitor.snapshot(include_subagents=True)), 2)

    def test_newest_duplicate_wins(self):
        self.path.write_bytes(self.header + event("task_started"))
        os.utime(self.path, (1000, 1000))
        newer = self.root / "newer.jsonl"
        newer.write_bytes(self.header + event("task_complete"))
        os.utime(newer, (2000, 2000))
        rows = Monitor(self.root).snapshot()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0].state, "completed")

    def test_missing_directory_is_explained(self):
        monitor = Monitor(self.root / "missing")
        self.assertEqual(monitor.snapshot(), [])
        self.assertTrue(monitor.warnings)

    def test_tail_window_skips_partial_first_record(self):
        self.path.write_bytes(self.header + record("response_item", content="x" * 1000)
                              + event("task_complete"))
        with patch("monitor.TAIL_BYTES", 100):
            row = read_session(self.path)
        self.assertEqual(row.id, "test-session")
        self.assertEqual(row.state, "completed")

    def test_missing_lifecycle_in_tail_is_unknown(self):
        self.path.write_bytes(self.header + event("task_started")
                              + record("response_item", content="x" * 1000))
        with patch("monitor.TAIL_BYTES", 100):
            self.assertEqual(read_session(self.path).state, "unknown")

    def test_oversized_or_incomplete_header_is_ignored(self):
        with patch("monitor.HEADER_BYTES", 10):
            self.assertEqual(read_session(self.path).id, "")
        self.path.write_bytes(self.header[:-1])
        self.assertEqual(read_session(self.path).id, "")

    def test_symlinks_are_not_followed(self):
        self.path.unlink()
        outside = self.root / "outside.txt"
        outside.write_bytes(self.header)
        self.path.symlink_to(outside)
        self.assertEqual(Monitor(self.root).snapshot(), [])

    def test_terminal_controls_and_bidi_are_removed(self):
        text = safe_text("hello\033[2J\n\u202eevil")
        self.assertNotIn("\033", text)
        self.assertNotIn("\n", text)
        self.assertNotIn("\u202e", text)

    def test_untrusted_numeric_and_usage_values(self):
        for value in [True, -1, float("nan"), float("inf"), "100", {}, 10 ** 1000]:
            row = Session()
            reduce_record(row, {"type": "event_msg", "payload": {
                "type": "token_count", "info": {"total_token_usage": {"total_tokens": value}}}})
            self.assertIsNone(row.total_tokens)
        row = Session(limit_used_percent=10)
        reduce_record(row, {"type": "event_msg", "payload": {"type": "token_count", "info": None}})
        self.assertIsNone(row.limit_used_percent)

    def test_json_cli_and_argument_validation(self):
        script = str(Path(__file__).with_name("monitor.py"))
        result = subprocess.run([sys.executable, script, "--json", "--sessions-dir", str(self.root)],
                                capture_output=True, text=True, check=True)
        data = json.loads(result.stdout)
        self.assertEqual(data["sessions"][0]["id"], "test-session")
        self.assertNotIn("\033", result.stdout)
        for args in [["--limit", "0"], ["--interval", "nan"], ["--stale-after", "-1"]]:
            result = subprocess.run([sys.executable, script] + args, capture_output=True)
            self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
