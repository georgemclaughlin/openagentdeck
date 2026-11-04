#!/usr/bin/env python3
"""A local, read-only Codex deck for a 1920 x 480 strip display."""

from __future__ import annotations

import argparse
from collections.abc import Callable
import math
import os
from pathlib import Path
import queue
import threading
import time
import tkinter as tk
from tkinter import font

from monitor import Activity, Monitor, Session, positive
from preferences import Preferences, default_preferences_path


BG = "#0c1118"
PANEL = "#151e29"
LINE = "#283545"
INK = "#eef4fa"
MUTED = "#8d9fb2"
COLORS = {"working": "#72b7ff", "completed": "#7bd9ad", "interrupted": "#e6ba73",
          "error": "#ff8893", "unknown": MUTED}


def age_label(updated_at: float, now: float) -> str:
    seconds = max(0, int(now - updated_at))
    if seconds < 60:
        return f"{seconds}s ago"
    if seconds < 3600:
        return f"{seconds // 60}m ago"
    if seconds < 86400:
        return f"{seconds // 3600}h ago"
    return f"{seconds // 86400}d ago"


def demo_sessions() -> list[Session]:
    now = time.time()
    return [Session(id=f"demo-{i + 1}", project=f"/projects/{project}", model="Codex · demo",
                    state=state, updated_at=now - age, stale=age > 120,
                    total_tokens=tokens, limit_used_percent=23, branch="feature/session-details",
                    title=title, last_prompt=title, last_activity="Tool: run_tests",
                    recent=[Activity("user", title), Activity("tool", "Tool: run_tests"),
                            Activity("assistant", "The session cards now show the latest task. "
                                     "I am checking the detail view and saved preferences.")])
            for i, (project, state, age, tokens, title) in enumerate([
                ("openagentdeck", "working", 3, 82400, "Add richer session cards and touch controls"),
                ("website", "completed", 38, 41280, "Fix the mobile navigation layout"),
                ("data-pipeline", "interrupted", 67, 19500, "Investigate the failed nightly import"),
                ("api-service", "working", 600, 56000, "Review the authentication middleware"),
                ("documentation", "unknown", 180, 0, "Update the Linux setup guide")])]


class Dashboard:
    def __init__(self, root: tk.Tk, sessions_dir: Path, *, demo: bool = False,
                 interval: float = 2, start_worker: bool = True,
                 preferences: Preferences | None = None):
        self.root = root
        self.demo = demo
        self.sessions: list[Session] = demo_sessions() if demo else []
        self.warnings: list[str] = []
        self.page = 0
        self.preferences = preferences or Preferences(None if demo else default_preferences_path())
        self.selected_id: str | None = None
        self.show_hidden = False
        self.notice = ""
        self.history_key: tuple | None = None
        self.fullscreen = False
        self.started = demo
        self.fonts: dict[tuple, font.Font] = {}
        self.actions: dict[str, Callable[[], None]] = {}
        self.messages: queue.Queue = queue.Queue(maxsize=1)
        self.stop = threading.Event()
        self.canvas = tk.Canvas(root, bg=BG, highlightthickness=0)
        self.canvas.pack(fill="both", expand=True)
        self.history = tk.Text(root, bg=PANEL, fg=INK, insertbackground=INK,
                               relief="flat", borderwidth=0, highlightthickness=0, wrap="word", padx=18, pady=12,
                               font=("DejaVu Sans", -16), selectbackground="#365879",
                               spacing1=2, spacing3=4, state="disabled", takefocus=True)
        self.history.tag_configure("label", foreground=MUTED, font=("DejaVu Sans", -12, "bold"))
        self.history.tag_configure("error", foreground=COLORS["error"])
        self.history_scroll = tk.Scrollbar(root, command=self.history.yview, bg=LINE,
                                          activebackground=MUTED, troughcolor=PANEL,
                                          highlightthickness=0, borderwidth=0, relief="flat")
        self.history.configure(yscrollcommand=self.history_scroll.set)
        root.title("Open Agent Deck · Codex")
        root.configure(bg=BG)
        root.minsize(720, 400)
        root.protocol("WM_DELETE_WINDOW", self.close)
        root.bind("<Escape>", lambda _: self.escape())
        root.bind("<F11>", lambda _: self.set_fullscreen(not self.fullscreen))
        root.bind("<Left>", lambda _: self.navigate(-1))
        root.bind("<Right>", lambda _: self.navigate(1))
        self.canvas.bind("<Configure>", lambda _: self.draw())
        self.canvas.bind("<Button-1>", self.handle_click)
        if start_worker and not demo:
            threading.Thread(target=self.collect, args=(sessions_dir, interval), daemon=True).start()
        self.timer = root.after(100, self.receive)

    def collect(self, sessions_dir: Path, interval: float) -> None:
        monitor = Monitor(sessions_dir)
        while not self.stop.is_set():
            try:
                rows = monitor.snapshot(limit=48, preferred_ids=set(self.preferences.pinned))
                message = (rows, monitor.warnings)
            except Exception:
                # Never put payload contents, paths, or a traceback into the display.
                message = ([], ["Session scan failed. Check the session folder and restart the deck."])
            try:
                self.messages.put_nowait(message)
            except queue.Full:
                pass
            self.stop.wait(interval)

    def receive(self) -> None:
        try:
            self.sessions, self.warnings = self.messages.get_nowait()
            self.started = True
        except queue.Empty:
            pass
        self.draw()
        self.timer = self.root.after(1000, self.receive)

    def close(self) -> None:
        self.stop.set()
        self.root.after_cancel(self.timer)
        self.root.destroy()

    def set_fullscreen(self, enabled: bool) -> None:
        self.fullscreen = enabled
        self.root.attributes("-fullscreen", enabled)
        self.draw()

    def slots(self) -> int:
        return max(1, min(4, (self.canvas.winfo_width() - 48) // 350))

    def change_page(self, direction: int) -> None:
        pages = max(1, math.ceil(len(self.visible_sessions()) / self.slots()))
        self.page = (self.page + direction) % pages
        self.draw()

    def visible_sessions(self) -> list[Session]:
        return self.preferences.visible(self.sessions, hidden=self.show_hidden)

    def handle_click(self, _) -> None:
        # One Tk callback for the lifetime of the canvas. Rebinding per-card
        # lambdas on every clock repaint retains thousands of Tcl commands.
        for tag in self.canvas.gettags("current"):
            action = self.actions.get(tag)
            if action is not None:
                action()
                return

    def select(self, session_id: str) -> None:
        self.selected_id = session_id
        self.history_key = None
        self.draw()

    def back(self) -> None:
        self.selected_id = None
        self.draw()

    def escape(self) -> None:
        if self.selected_id:
            self.back()
        else:
            self.set_fullscreen(False)

    def navigate(self, direction: int) -> None:
        if self.selected_id:
            # History is newest first: Older moves down, Newer moves up.
            self.history.yview_scroll(-direction, "pages")
            self.draw()
        else:
            self.change_page(direction)

    def toggle_hidden_view(self) -> None:
        self.show_hidden = not self.show_hidden
        self.selected_id = None
        self.page = 0
        self.draw()

    def change_preference(self, field: str) -> None:
        if self.selected_id and self.preferences.change(self.selected_id, field):
            if field == "hidden":
                self.selected_id = None
            self.notice = ""
        self.draw()

    def restore_all(self) -> None:
        if self.preferences.save(hidden=set()):
            self.show_hidden = False
            self.page = 0
        self.draw()

    def get_font(self, size: int, bold: bool = False) -> font.Font:
        key = size, bold
        if key not in self.fonts:
            self.fonts[key] = font.Font(family="DejaVu Sans", size=-size,
                                        weight="bold" if bold else "normal")
        return self.fonts[key]

    def text(self, x: float, y: float, value: str, *, size: int = 16,
             color: str = INK, bold: bool = False, width: float | None = None,
             anchor: str = "nw", tag: str = "") -> int:
        face = self.get_font(size, bold)
        if width is not None and face.measure(value) > width:
            lo, hi = 0, len(value)
            while lo < hi:
                middle = (lo + hi + 1) // 2
                if face.measure(value[:middle] + "…") <= width:
                    lo = middle
                else:
                    hi = middle - 1
            value = value[:lo] + "…"
        return self.canvas.create_text(x, y, text=value, fill=color, font=face,
                                        anchor=anchor, tags=tag)

    def box(self, x: float, y: float, right: float, bottom: float,
            fill: str, *, tag: str = "", radius: int = 14, outline: str = "") -> None:
        r = radius
        points = [x+r,y,right-r,y,right,y,right,y+r,right,bottom-r,right,bottom,
                  right-r,bottom,x+r,bottom,x,bottom,x,bottom-r,x,y+r,x,y]
        self.canvas.create_polygon(points, smooth=True, splinesteps=20, fill=fill,
                                   outline=outline, tags=tag)

    def button(self, x: float, y: float, width: int, label: str, tag: str, action,
               enabled: bool = True) -> None:
        self.box(x, y, x + width, y + 56, PANEL, tag=tag, outline=LINE)
        self.text(x + width / 2, y + 28, label, size=17,
                  color=INK if enabled else MUTED, anchor="center", tag=tag)
        if enabled:
            self.actions[tag] = action

    def wrapped(self, x: float, y: float, value: str, width: float, *, size: int = 20,
                lines: int = 2, color: str = INK, tag: str = "") -> None:
        words = value.split()
        for line in range(lines):
            if not words:
                return
            if line == lines - 1:
                value = " ".join(words)
            else:
                value = words.pop(0)
                while words and self.get_font(size).measure(value + " " + words[0]) <= width:
                    value += " " + words.pop(0)
            self.text(x, y + line * (size + 7), value, size=size, color=color, width=width, tag=tag)

    def draw_card(self, session: Session, x: float, top: float, right: float,
                  bottom: float, now: float) -> None:
        tag = "session:" + session.id
        color = MUTED if session.stale else COLORS.get(session.state, MUTED)
        self.box(x, top, right, bottom, PANEL, outline=LINE, tag=tag)
        self.canvas.create_rectangle(x + 18, top + 22, x + 22, bottom - 22,
                                     fill=color, outline="", tags=tag)
        tx, available = x + 38, right - x - 60
        pinned = session.id in self.preferences.pinned
        project = Path(session.project).name or "Unnamed project"
        self.text(tx, top + 18, project, size=21, bold=True,
                  width=available - (80 if pinned else 0), tag=tag)
        if pinned:
            self.text(right - 22, top + 22, "PINNED", size=11, color="#e6ba73", bold=True, anchor="ne", tag=tag)
        self.text(tx, top + 48, session.branch or "Branch unavailable", size=13,
                  color=MUTED, width=available, tag=tag)
        headline = session.title or session.last_prompt or "No prompt in recent records"
        self.wrapped(tx, top + 77, headline, available, size=19, tag=tag)
        self.text(tx, top + 137, session.state.upper(), size=21, bold=True, color=color, tag=tag)
        freshness = "No recent update" if session.stale else "Updated"
        self.text(tx, top + 168, f"{freshness} · {age_label(session.updated_at, now)}", size=13,
                  color="#e6ba73" if session.stale else MUTED, width=available, tag=tag)
        if bottom - top >= 270:
            self.text(tx, top + 203, session.last_activity or "No recent activity recorded", size=14,
                      color=MUTED, width=available, tag=tag)
        label = "Hidden · tap to restore" if self.show_hidden else "Tap for details"
        self.text(tx, bottom - 30, label, size=12, color=MUTED, tag=tag)
        self.text(right - 22, bottom - 30, session.id[:8], size=11, color=MUTED, anchor="ne", tag=tag)
        self.actions[tag] = lambda sid=session.id: self.select(sid)

    def draw_details(self, session: Session, w: int, h: int, now: float) -> None:
        top, bottom = 99, h - 83
        project = Path(session.project).name or "Unnamed project"
        color = MUTED if session.stale else COLORS.get(session.state, MUTED)
        if w >= 1100:
            right = min(490, w * .33)
            self.box(26, top, right, bottom, PANEL, outline=LINE)
            self.text(46, top + 18, project, size=23, bold=True, width=right - 70)
            self.text(46, top + 51, session.branch or "Branch unavailable", size=14, color=MUTED, width=right - 70)
            self.wrapped(46, top + 79, session.title or session.last_prompt or "Untitled session",
                         right - 70, size=18)
            self.text(46, top + 137, session.state.upper(), size=23, bold=True, color=color)
            self.text(46, top + 169, session.model or "Model unavailable", size=14, color=MUTED, width=right - 70)
            if bottom - top >= 270:
                self.text(46, top + 199, session.project or "Directory unavailable", size=12,
                          color=MUTED, width=right - 70)
                tokens = f"{session.total_tokens:,}" if session.total_tokens is not None else "—"
                rate = f"{session.limit_used_percent:g}%" if session.limit_used_percent is not None else "—"
                self.text(46, bottom - 60, f"Tokens {tokens} · Limit used {rate}", size=13, width=right - 70)
            freshness = "Stale" if session.stale else "Updated"
            self.text(46, bottom - 31, f"{freshness} · {age_label(session.updated_at, now)}", size=13,
                      color="#e6ba73" if session.stale else MUTED, width=right - 70)
            history_x, history_top = right + 16, top + 37
        else:
            self.text(28, top + 4, project, size=21, bold=True, width=w - 250)
            self.text(w - 28, top + 9, session.state.upper(), size=16, color=color, anchor="ne")
            self.text(28, top + 35, session.title or session.last_prompt or session.branch or "Untitled session",
                      size=16, color=MUTED, width=w - 56)
            history_x, history_top = 26, top + 68
        self.history.place(x=history_x, y=history_top, width=w - history_x - 44, height=bottom - history_top)
        self.history_scroll.place(x=w - 44, y=history_top, width=18, height=bottom - history_top)
        # Keep text selection and scroll position stable across clock repaints.
        key = (session.id, session.last_prompt, session.error,
               tuple((a.kind, a.text, a.timestamp) for a in session.recent))
        # While someone reads older messages, keep that snapshot intact. Refresh
        # when they return to the newest entry instead of moving text under them.
        if key != self.history_key and (self.history_key is None or self.history.yview()[0] <= .02):
            self.history.configure(state="normal")
            self.history.delete("1.0", "end")
            entries = list(session.recent)
            if session.last_prompt and not any(a.kind == "user" and a.text == session.last_prompt for a in entries):
                entries.insert(0, Activity("user", session.last_prompt))
            if session.error and not any(a.kind == "error" and a.text == session.error for a in entries):
                entries.append(Activity("error", session.error))
            if not entries:
                self.history.insert("end", "No messages in the recent file window.\n\n"
                                    "Older history may exist in Codex; this view reads only a bounded file tail.")
            for entry in reversed(entries):
                label = {"user": "YOU", "assistant": "CODEX", "tool": "TOOL", "error": "ERROR",
                         "status": "ACTIVITY"}.get(entry.kind, "ACTIVITY")
                stamp = f"  ·  {entry.timestamp}" if entry.timestamp else ""
                self.history.insert("end", label + stamp + "\n", "label")
                self.history.insert("end", entry.text + "\n\n", "error" if entry.kind == "error" else "body")
            self.history.configure(state="disabled")
            self.history.yview_moveto(0)
            self.history_key = key
        if w >= 1100:
            label = ("NEW ACTIVITY · use Newer to return to the latest" if key != self.history_key
                     else "RECENT MESSAGES & ACTIVITY")
            self.text(history_x, top + 6, label, size=12, color=MUTED, bold=True, width=w - history_x - 44)
        self.button(26, h - 70, 94, "Back", "back", self.back)
        self.button(132, h - 70, 112, "Unpin" if session.id in self.preferences.pinned else "Pin",
                    "pin", lambda: self.change_preference("pinned"))
        self.button(256, h - 70, 124, "Show again" if session.id in self.preferences.hidden else "Hide",
                    "hide", lambda: self.change_preference("hidden"))
        if w >= 1100:
            self.text(402, h - 49, self.preferences.warning or "Recorded history · session " + session.id[:12],
                      size=13, color=MUTED, width=w - 650)
        elif self.preferences.warning:
            self.text(28, 79, self.preferences.warning, size=11, color=COLORS["error"], width=w - 56)
        self.button(w - 202, h - 70, 80, "Older", "older", lambda: self.navigate(-1))
        self.button(w - 108, h - 70, 80, "Newer", "newer", lambda: self.navigate(1))

    def draw(self) -> None:
        c = self.canvas
        w, h = c.winfo_width(), c.winfo_height()
        if w < 100 or h < 100:
            return
        self.actions.clear()
        c.delete("all")
        c.create_rectangle(0, 0, w, h, fill=BG, outline="")
        now = time.time()
        slots = self.slots()
        rows = self.visible_sessions()
        pages = max(1, math.ceil(len(rows) / slots))
        self.page = min(self.page, pages - 1)
        self.text(28, 19, "OPEN AGENT DECK", size=13, color=MUTED, bold=True)
        self.text(26, 40, "Hidden" if self.show_hidden else "Codex", size=33, bold=True)
        if w >= 1100:
            fresh = sum(s.state == "working" and not s.stale for s in rows)
            self.text(192, 51, f"{fresh} recently working  /  {len(rows)} sessions",
                      size=18, color=MUTED, width=w - 640)
        label = "DEMO DATA" if self.demo else "OBSERVE ONLY"
        self.text(w - 360, 23, label, size=12, color="#7bd9ad", bold=True)
        self.text(w - 360, 47, time.strftime("%H:%M"), size=24)
        self.button(w - 222, 18, 118, "Window" if self.fullscreen else "Fullscreen",
                    "fullscreen", lambda: self.set_fullscreen(not self.fullscreen))
        self.button(w - 92, 18, 64, "Exit", "exit", self.close)

        selected = next((s for s in self.sessions if s.id == self.selected_id), None)
        if selected:
            self.draw_details(selected, w, h, now)
            return
        if self.selected_id:
            self.selected_id = None
            self.notice = "That session is no longer in the current scan."
        self.history.place_forget()
        self.history_scroll.place_forget()
        top, bottom, gap, margin = 99, h - 83, 16, 26
        card_width = (w - margin * 2 - gap * (slots - 1)) / slots
        visible = rows[self.page * slots:(self.page + 1) * slots]
        for i, session in enumerate(visible):
            x = margin + i * (card_width + gap)
            self.draw_card(session, x, top, x + card_width, bottom, now)
        if not visible:
            self.box(margin, top, w - margin, bottom, PANEL, outline=LINE)
            title = "Looking for your Codex sessions…" if not self.started else "No sessions in this view"
            self.text(w / 2, top + 58, title, size=28, bold=True, anchor="n")
            subtitle = ("Use Show again on a hidden card, or Restore all to clear your hidden list."
                        if self.show_hidden else "Use Codex normally, or check Hidden for sessions you put away.")
            self.text(w / 2, top + 109, subtitle, size=17, color=MUTED, anchor="n", width=w - 100)
        self.button(26, h - 70, 144, "All sessions" if self.show_hidden else f"Hidden ({len(self.preferences.hidden)})",
                    "hidden-view", self.toggle_hidden_view)
        footer = self.preferences.warning or self.notice or (self.warnings[0] if self.warnings else
                  "Tap a card for details · pins stay first")
        if self.show_hidden:
            self.button(182, h - 70, 132, "Restore all", "restore-all", self.restore_all,
                        bool(self.preferences.hidden))
            if w >= 1100:
                self.text(334, h - 49, footer, size=13, color=MUTED, width=w - 650)
        else:
            self.text(190, h - 49, footer, size=13, color=MUTED, width=w - 500)
        self.text(w - 274, h - 49, f"{self.page + 1} / {pages}", size=16, color=MUTED)
        self.button(w - 202, h - 70, 80, "‹", "previous", lambda: self.change_page(-1), pages > 1)
        self.button(w - 108, h - 70, 80, "›", "next", lambda: self.change_page(1), pages > 1)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sessions-dir", type=Path,
                        default=Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))) / "sessions")
    parser.add_argument("--geometry", default="1920x480", help="Tk window geometry, e.g. 1920x480+320+1440")
    parser.add_argument("--fullscreen", action="store_true")
    parser.add_argument("--demo", action="store_true", help="show synthetic sessions without reading Codex data")
    parser.add_argument("--interval", type=positive, default=2)
    parser.add_argument("--preferences-file", type=Path, default=None,
                        help="override the deck's pin/hide settings file; demo mode never writes settings")
    args = parser.parse_args()
    try:
        root = tk.Tk()
    except tk.TclError as exc:
        parser.exit(1, f"Could not open a desktop window: {exc}\nUse linux/monitor.py on a headless machine.\n")
    try:
        root.geometry(args.geometry)
    except tk.TclError:
        root.destroy()
        parser.error("invalid window geometry")
    preferences = Preferences(None if args.demo else (args.preferences_file or default_preferences_path()).expanduser())
    dashboard = Dashboard(root, args.sessions_dir.expanduser(), demo=args.demo, interval=args.interval,
                          preferences=preferences)
    if args.fullscreen:
        root.after(500, lambda: dashboard.set_fullscreen(True))
    root.mainloop()


if __name__ == "__main__":
    main()
