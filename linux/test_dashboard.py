"""Display-independent helpers and optional real Tk interaction checks."""

from pathlib import Path
import tkinter as tk
import unittest

from dashboard import Dashboard, age_label


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
        self.app.draw()
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
