#!/usr/bin/env python3
"""A local, read-only Codex deck for a 1920 x 480 strip display."""

from __future__ import annotations

import argparse
import math
import os
from pathlib import Path
import queue
import threading
import time
import tkinter as tk
from tkinter import font

from monitor import Monitor, Session, positive


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
                    total_tokens=tokens, limit_used_percent=23)
            for i, (project, state, age, tokens) in enumerate([
                ("openagentdeck", "working", 3, 82400),
                ("website", "completed", 38, 41280),
                ("data-pipeline", "interrupted", 67, 19500),
                ("api-service", "working", 600, 56000),
                ("documentation", "unknown", 180, 0)])]


class Dashboard:
    def __init__(self, root: tk.Tk, sessions_dir: Path, *, demo: bool = False,
                 interval: float = 2, start_worker: bool = True):
        self.root = root
        self.demo = demo
        self.sessions: list[Session] = demo_sessions() if demo else []
        self.warnings: list[str] = []
        self.page = 0
        self.fullscreen = False
        self.started = demo
        self.fonts: dict[tuple, font.Font] = {}
        self.messages: queue.Queue = queue.Queue(maxsize=1)
        self.stop = threading.Event()
        self.canvas = tk.Canvas(root, bg=BG, highlightthickness=0)
        self.canvas.pack(fill="both", expand=True)
        root.title("Open Agent Deck · Codex")
        root.configure(bg=BG)
        root.minsize(720, 360)
        root.protocol("WM_DELETE_WINDOW", self.close)
        root.bind("<Escape>", lambda _: self.set_fullscreen(False))
        root.bind("<F11>", lambda _: self.set_fullscreen(not self.fullscreen))
        root.bind("<Left>", lambda _: self.change_page(-1))
        root.bind("<Right>", lambda _: self.change_page(1))
        self.canvas.bind("<Configure>", lambda _: self.draw())
        if start_worker and not demo:
            threading.Thread(target=self.collect, args=(sessions_dir, interval), daemon=True).start()
        self.timer = root.after(100, self.receive)

    def collect(self, sessions_dir: Path, interval: float) -> None:
        monitor = Monitor(sessions_dir)
        while not self.stop.is_set():
            try:
                rows = monitor.snapshot(limit=48)
                # Put fresh working observations first, retaining recency within each group.
                rows.sort(key=lambda row: (row.stale, row.state != "working", -row.updated_at))
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
        pages = max(1, math.ceil(len(self.sessions) / self.slots()))
        self.page = (self.page + direction) % pages
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
            self.canvas.tag_bind(tag, "<Button-1>", lambda _: action())

    def draw(self) -> None:
        c = self.canvas
        w, h = c.winfo_width(), c.winfo_height()
        if w < 100 or h < 100:
            return
        c.delete("all")
        c.create_rectangle(0, 0, w, h, fill=BG, outline="")
        now = time.time()
        slots = self.slots()
        pages = max(1, math.ceil(len(self.sessions) / slots))
        self.page = min(self.page, pages - 1)
        self.text(28, 19, "OPEN AGENT DECK", size=13, color=MUTED, bold=True)
        self.text(26, 40, "Codex", size=33, bold=True)
        if w >= 1100:
            fresh = sum(s.state == "working" and not s.stale for s in self.sessions)
            self.text(192, 51, f"{fresh} recently working  /  {len(self.sessions)} recorded sessions",
                      size=18, color=MUTED, width=w - 640)
        label = "DEMO DATA" if self.demo else "OBSERVE ONLY"
        self.text(w - 360, 23, label, size=12, color="#7bd9ad", bold=True)
        self.text(w - 360, 47, time.strftime("%H:%M"), size=24)
        self.button(w - 222, 18, 118, "Window" if self.fullscreen else "Fullscreen",
                    "fullscreen", lambda: self.set_fullscreen(not self.fullscreen))
        self.button(w - 92, 18, 64, "Exit", "exit", self.close)

        top, bottom, gap, margin = 99, h - 83, 16, 26
        card_width = (w - margin * 2 - gap * (slots - 1)) / slots
        visible = self.sessions[self.page * slots:(self.page + 1) * slots]
        for i, session in enumerate(visible):
            x = margin + i * (card_width + gap)
            right = x + card_width
            color = COLORS.get(session.state, MUTED)
            self.box(x, top, right, bottom, PANEL, outline=LINE)
            c.create_rectangle(x + 18, top + 22, x + 22, bottom - 22,
                               fill=MUTED if session.stale else color, outline="")
            tx, available = x + 40, card_width - 62
            project = Path(session.project).name or "Unnamed project"
            self.text(tx, top + 24, project, size=26, bold=True, width=available)
            self.text(tx, top + 61, session.model or "Model unavailable", size=15,
                      color=MUTED, width=available)
            self.text(tx, top + 101, session.state.upper(), size=28, bold=True,
                      color=MUTED if session.stale else color, width=available)
            freshness = "No recent update" if session.stale else "Last update"
            self.text(tx, top + 142, f"{freshness} · {age_label(session.updated_at, now)}",
                      color="#e6ba73" if session.stale else MUTED, size=16, width=available)
            if bottom - top >= 270:
                c.create_line(tx, bottom - 89, right - 22, bottom - 89, fill=LINE)
                tokens = f"{session.total_tokens:,}" if session.total_tokens is not None else "—"
                self.text(tx, bottom - 72, tokens, size=21, bold=True, width=available / 2)
                self.text(tx, bottom - 42, "SESSION TOKENS", size=10, color=MUTED, bold=True)
                rate = f"{session.limit_used_percent:g}%" if session.limit_used_percent is not None else "—"
                self.text(right - 22, bottom - 72, rate, size=21, bold=True, anchor="ne")
                self.text(right - 22, bottom - 42, "LIMIT USED", size=10,
                          color=MUTED, bold=True, anchor="ne")
            else:
                self.text(tx, bottom - 34, session.id[:16], size=12, color=MUTED, width=available)

        if not visible:
            self.box(margin, top, w - margin, bottom, PANEL, outline=LINE)
            title = "Looking for your Codex sessions…" if not self.started else "No recorded sessions yet"
            self.text(w / 2, top + 58, title, size=28, bold=True, anchor="n")
            self.text(w / 2, top + 109, "Use Codex normally. Sessions saved on this machine will appear here.",
                      size=17, color=MUTED, anchor="n", width=w - 100)

        footer = "Recorded activity · approvals stay in Codex · Esc leaves fullscreen"
        if self.warnings:
            footer = self.warnings[0]
        self.text(28, h - 49, footer, size=14, color=MUTED, width=w - 355)
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
    dashboard = Dashboard(root, args.sessions_dir.expanduser(), demo=args.demo, interval=args.interval)
    if args.fullscreen:
        root.after(500, lambda: dashboard.set_fullscreen(True))
    root.mainloop()


if __name__ == "__main__":
    main()
