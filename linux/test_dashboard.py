"""Display-independent helpers and optional real Tk interaction checks."""

from pathlib import Path
import tkinter as tk
import unittest

from dashboard import Dashboard, age_label, demo_sessions
from monitor import Activity
from preferences import Preferences


class DisplayHelpersTests(unittest.TestCase):
    def test_age_units_and_future_timestamps(self):
        for elapsed, expected in [(3, "3s ago"), (90, "1m ago"), (7200, "2h ago"),
                                  (172800, "2d ago"), (-10, "0s ago")]:
            self.assertEqual(age_label(1000, 1000 + elapsed), expected)


class DashboardTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        try:
            cls.root = tk.Tk()
        except tk.TclError:
            raise unittest.SkipTest("No graphical display available")
        cls.root.geometry("1920x480+0+0")
        cls.app = Dashboard(cls.root, Path("/unused"), demo=True, start_worker=False)
        cls.root.update()

    @classmethod
    def tearDownClass(cls):
        cls.app.close()

    def setUp(self):
        self.app.page = 0
        self.app.selected_id = None
        self.app.show_hidden = False
        self.app.preferences = Preferences(None)
        self.app.sessions = demo_sessions()
        self.app.notice = ""
        self.app.draw()
        self.root.update()

    def click(self, tag):
        left, top, right, bottom = self.app.canvas.bbox(tag)
        x, y = (left + right) // 2, (top + bottom) // 2
        self.app.canvas.event_generate("<Motion>", x=x, y=y)
        self.app.canvas.event_generate("<Button-1>", x=x, y=y)
        self.root.update()

    def test_card_opens_the_correct_detail_and_back_returns_to_overview(self):
        self.click("session:demo-2")
        self.assertEqual(self.app.selected_id, "demo-2")
        self.assertTrue(self.app.history.winfo_ismapped())
        self.assertIn("Fix the mobile navigation layout", self.app.history.get("1.0", "end"))
        self.assertEqual(self.app.history.cget("state"), "disabled")
        self.click("back")
        self.assertIsNone(self.app.selected_id)
        self.assertFalse(self.app.history.winfo_ismapped())

    def test_pin_hide_and_restore_through_touch_controls(self):
        self.click("session:demo-2")
        self.click("pin")
        self.assertIn("demo-2", self.app.preferences.pinned)
        self.assertEqual(self.app.visible_sessions()[0].id, "demo-2")
        self.click("hide")
        self.assertIsNone(self.app.selected_id)
        self.assertNotIn("demo-2", [s.id for s in self.app.visible_sessions()])
        self.click("hidden-view")
        self.assertEqual([s.id for s in self.app.visible_sessions()], ["demo-2"])
        self.click("session:demo-2")
        self.click("hide")
        self.assertNotIn("demo-2", self.app.preferences.hidden)
        self.click("hidden-view")
        self.assertEqual(self.app.visible_sessions()[0].id, "demo-2")

    def test_selection_survives_reordering_and_handles_disappearance(self):
        self.app.select("demo-2")
        self.app.sessions.reverse()
        self.app.draw()
        self.assertEqual(self.app.selected_id, "demo-2")
        self.assertIn("Fix the mobile navigation layout", self.app.history.get("1.0", "end"))
        self.app.sessions = [s for s in self.app.sessions if s.id != "demo-2"]
        self.app.draw()
        self.assertIsNone(self.app.selected_id)
        self.assertIn("no longer", self.app.notice)

    def test_detail_scroll_position_is_not_reset_by_updates(self):
        row = self.app.sessions[0]
        row.recent = [Activity("assistant", f"Message {i}: " + "A long response. " * 40) for i in range(12)]
        self.app.select(row.id)
        self.root.update()
        self.app.history.yview_moveto(0)
        self.app.draw()
        self.assertEqual(self.app.history.yview()[0], 0)
        row.recent.append(Activity("tool", "Tool: build"))
        self.app.draw()
        self.root.update()
        self.assertEqual(self.app.history.yview()[0], 0)

    def test_latest_activity_is_first_and_older_button_scrolls_down(self):
        row = self.app.sessions[0]
        row.recent = [Activity("assistant", f"Update {i}. " + "Details. " * 40) for i in range(12)]
        self.app.select(row.id)
        self.root.update()
        self.assertIn("Update 11", self.app.history.get("1.0", "4.0"))
        self.assertEqual(self.app.history.yview()[0], 0)
        self.click("older")
        self.assertGreater(self.app.history.yview()[0], 0)
        # Tk refines total-height estimates lazily; compare the visible text
        # position, not the scrollbar's fraction of that estimated total.
        before = self.app.history.index("@0,0")
        row.recent.append(Activity("tool", "Tool: build"))
        self.app.draw()
        self.root.update()
        self.assertEqual(self.app.history.index("@0,0"), before)
        self.assertNotIn("Tool: build", self.app.history.get("1.0", "end"))
        self.click("newer")
        self.assertIn("Tool: build", self.app.history.get("1.0", "4.0"))

    def test_restore_all_also_clears_hidden_ids_outside_the_scan(self):
        self.app.preferences.save(hidden={"demo-1", "old-unloaded-session"})
        self.click("hidden-view")
        self.click("restore-all")
        self.assertFalse(self.app.show_hidden)
        self.assertEqual(self.app.preferences.hidden, set())

    def test_details_fit_both_strip_and_narrow_window(self):
        self.app.select("demo-1")
        try:
            for width, height in [(1920, 480), (800, 400)]:
                self.root.geometry(f"{width}x{height}+0+0")
                self.root.update()
                self.app.draw()
                self.root.update()
                for tag in ("back", "pin", "hide", "older", "newer"):
                    left, top, right, bottom = self.app.canvas.bbox(tag)
                    self.assertGreaterEqual(left, 0)
                    self.assertLessEqual(right, width)
                    self.assertLessEqual(bottom, height)
                    self.assertGreaterEqual(bottom - top, 56)
                self.assertGreater(self.app.history.winfo_height(), 100)
                self.assertLessEqual(self.app.history.winfo_x() + self.app.history.winfo_width(), width)
        finally:
            self.root.geometry("1920x480+0+0")
            self.root.update()

    def test_touch_navigation_changes_the_visible_sessions(self):
        # Generate real canvas pointer events over the navigation target.
        canvas = self.app.canvas
        canvas.event_generate("<Motion>", x=canvas.winfo_width() - 68,
                              y=canvas.winfo_height() - 42)
        canvas.event_generate("<Button-1>", x=canvas.winfo_width() - 68,
                              y=canvas.winfo_height() - 42)
        self.root.update()
        self.assertEqual(self.app.page, 1)
        texts = [canvas.itemcget(item, "text") for item in canvas.find_all()
                 if canvas.type(item) == "text"]
        self.assertIn("documentation", texts)
        self.assertNotIn("openagentdeck", texts)

    def test_touch_targets_are_at_least_56_pixels_high(self):
        for tag in ["previous", "next", "fullscreen", "exit"]:
            left, top, right, bottom = self.app.canvas.bbox(tag)
            self.assertGreaterEqual(right - left, 56)
            self.assertGreaterEqual(bottom - top, 56)

    def test_clock_repaints_do_not_accumulate_tk_callbacks(self):
        before = set(self.root.tk.call("info", "commands"))
        for _ in range(40):
            self.app.draw()
        after = set(self.root.tk.call("info", "commands"))
        self.assertEqual(after, before)
        self.click("session:demo-1")
        self.assertEqual(self.app.selected_id, "demo-1")

    def test_all_labels_fit_the_strip(self):
        canvas = self.app.canvas
        for item in canvas.find_all():
            if canvas.type(item) == "text":
                left, top, right, bottom = canvas.bbox(item)
                self.assertGreaterEqual(left, 0)
                self.assertGreaterEqual(top, 0)
                self.assertLessEqual(right, 1920)
                self.assertLessEqual(bottom, 480)

    def test_smaller_window_adjusts_card_count(self):
        self.root.geometry("800x400+0+0")
        self.root.update()
        self.assertEqual(self.app.slots(), 2)
        self.root.geometry("1920x480+0+0")
        self.root.update()

    def test_empty_state_does_not_keep_an_invalid_page(self):
        rows = self.app.sessions
        try:
            self.app.page = 9
            self.app.sessions = []
            self.app.draw()
            self.assertEqual(self.app.page, 0)
        finally:
            self.app.sessions = rows


if __name__ == "__main__":
    unittest.main()
