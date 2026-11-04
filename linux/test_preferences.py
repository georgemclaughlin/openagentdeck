import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from monitor import Session
from preferences import Preferences


class PreferencesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "deck" / "preferences.json"

    def test_pins_and_hidden_ids_survive_restart_without_saving_content(self):
        prefs = Preferences(self.path)
        self.assertFalse(self.path.exists())
        self.assertTrue(prefs.change("session-a", "pinned"))
        self.assertTrue(prefs.change("session-b", "hidden"))
        reopened = Preferences(self.path)
        self.assertEqual(reopened.pinned, {"session-a"})
        self.assertEqual(reopened.hidden, {"session-b"})
        self.assertEqual(set(json.loads(self.path.read_text())), {"pinned", "hidden"})
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)

    def test_unknown_preferences_are_preserved(self):
        self.path.parent.mkdir()
        self.path.write_text('{"future_setting": {"keep": true}}')
        prefs = Preferences(self.path)
        prefs.change("a", "pinned")
        self.assertEqual(json.loads(self.path.read_text())["future_setting"], {"keep": True})

    def test_corrupt_preferences_are_not_overwritten(self):
        self.path.parent.mkdir()
        for raw in ["broken", "[]", '{"hidden": [5]}']:
            self.path.write_text(raw)
            prefs = Preferences(self.path)
            self.assertTrue(prefs.warning)
            self.assertFalse(prefs.change("a", "pinned"))
            self.assertEqual(self.path.read_text(), raw)

    def test_failed_save_does_not_apply_action_or_destroy_previous_file(self):
        prefs = Preferences(self.path)
        prefs.change("a", "pinned")
        before = self.path.read_bytes()
        with patch("preferences.os.replace", side_effect=PermissionError):
            self.assertFalse(prefs.change("a", "hidden"))
        self.assertEqual(prefs.hidden, set())
        self.assertEqual(self.path.read_bytes(), before)
        self.assertTrue(prefs.warning)
        self.assertEqual(list(self.path.parent.glob(".preferences-*")), [])

    def test_pinned_sessions_sort_first_and_hidden_can_be_restored(self):
        prefs = Preferences(None)
        rows = [Session(id="old", stale=True, updated_at=1),
                Session(id="working", state="working", updated_at=3),
                Session(id="done", state="completed", updated_at=2)]
        prefs.change("old", "pinned")
        prefs.change("working", "hidden")
        self.assertEqual([s.id for s in prefs.visible(rows)], ["old", "done"])
        self.assertEqual([s.id for s in prefs.visible(rows, hidden=True)], ["working"])
        prefs.save(hidden=set())
        self.assertEqual([s.id for s in prefs.visible(rows)], ["old", "working", "done"])
        self.assertEqual(prefs.pinned, {"old"})

    def test_reading_preferences_does_not_write(self):
        prefs = Preferences(self.path)
        prefs.save()
        before = self.path.stat().st_mtime_ns
        Preferences(self.path)
        self.assertEqual(self.path.stat().st_mtime_ns, before)


if __name__ == "__main__":
    unittest.main()
