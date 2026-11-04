#!/usr/bin/env python3
"""Read-only Codex rollout monitor. Python 3.10+, no third-party dependencies."""

from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass, field, replace
import json
import math
import os
from pathlib import Path
import re
import shutil
import sys
import time
import unicodedata


HEADER_BYTES = 1024 * 1024
TAIL_BYTES = 512 * 1024


def safe_text(value: object, limit: int = 512, *, multiline: bool = False) -> str:
    """Never allow rollout content to inject terminal controls or bidi overrides."""
    if not isinstance(value, str):
        return ""
    return "".join(c if not unicodedata.category(c).startswith("C") or (multiline and c == "\n")
                   else " " for c in value[:limit]).strip()


def number(value: object) -> float | None:
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        try:
            if math.isfinite(value) and value >= 0:
                return value
        except OverflowError:
            pass
    return None


def object_of(value: object) -> dict:
    return value if isinstance(value, dict) else {}


@dataclass
class Activity:
    kind: str
    text: str
    timestamp: str = ""


@dataclass
class Session:
    id: str = ""
    project: str = ""
    model: str = ""
    state: str = "unknown"
    updated_at: float = 0
    stale: bool = False
    subagent: bool = False
    total_tokens: int | None = None
    limit_used_percent: float | None = None
    title: str = ""
    branch: str = ""
    last_prompt: str = ""
    last_activity: str = ""
    error: str = ""
    recent: list[Activity] = field(default_factory=list)


def content_text(content: object) -> str:
    """Only plain human-facing text; never reasoning, encrypted blocks or tool output."""
    if isinstance(content, str):
        return safe_text(content, 2000, multiline=True)
    if not isinstance(content, list):
        return ""
    parts = []
    for block in content[:32]:
        block = object_of(block)
        if block.get("type") in ("input_text", "output_text", "text", "Text"):
            parts.append(safe_text(block.get("text"), 2000, multiline=True))
    return "\n".join(parts)[:2000].strip()


def add_activity(session: Session, kind: str, text: object, row: dict) -> None:
    text = safe_text(text, 2000, multiline=True)
    if not text:
        return
    # Some Codex versions write the same message as both an item and an event.
    if not session.recent or (session.recent[-1].kind, session.recent[-1].text) != (kind, text):
        session.recent.append(Activity(kind, text, safe_text(row.get("timestamp"))))
        session.recent = session.recent[-12:]
    if kind == "user":
        session.last_prompt = text
    elif kind in ("assistant", "tool", "error"):
        session.last_activity = safe_text(text)


def add_message(session: Session, role: str, text: str, row: dict) -> None:
    if role == "user":
        # Runtime setup blocks are user-role messages in some rollout versions.
        text = re.sub(r"<environment_context>.*?</environment_context>", "", text, flags=re.S).strip()
        if text.startswith(("# AGENTS.md instructions", "<turn_aborted>", "<permissions instructions>",
                            "<environment_context>")):
            return
    add_activity(session, role, text, row)


def decode(line: bytes) -> dict:
    try:
        return object_of(json.loads(line))
    except (ValueError, UnicodeDecodeError, RecursionError):
        return {}


def reduce_record(session: Session, row: dict) -> None:
    payload = object_of(row.get("payload"))
    kind = row.get("type")
    if kind == "session_meta":
        session.id = safe_text(payload.get("id"))
        session.project = safe_text(payload.get("cwd"))
        session.branch = safe_text(object_of(payload.get("git")).get("branch"))
        session.title = safe_text(payload.get("thread_name") or payload.get("title"))
        source = object_of(payload.get("source"))
        session.subagent = bool(payload.get("parent_thread_id") or source.get("subagent"))
    elif kind == "turn_context":
        session.model = safe_text(payload.get("model"))
        session.project = safe_text(payload.get("cwd")) or session.project
    elif kind == "response_item":
        item_type = payload.get("type")
        role = payload.get("role")
        if item_type == "message" and role in ("user", "assistant"):
            if payload.get("phase") not in (None, "commentary", "final", "final_answer"):
                return
            add_message(session, role, content_text(payload.get("content")), row)
        elif item_type in ("function_call", "custom_tool_call"):
            name = safe_text(payload.get("name"))
            if name:
                add_activity(session, "tool", f"Tool: {name}", row)
    elif kind == "event_msg":
        event = payload.get("type")
        if event == "task_started":
            session.state = "working"
            session.error = ""
            session.last_activity = "Turn started"
            add_activity(session, "status", "Turn started", row)
        elif event == "task_complete":
            session.state = "error" if payload.get("error") else "completed"
            error = payload.get("error")
            session.error = safe_text(object_of(error).get("message") if isinstance(error, dict) else error,
                                      2000, multiline=True)
            if session.error:
                add_activity(session, "error", session.error, row)
            # Older versions may provide the final reply only on task_complete.
            reply = safe_text(payload.get("last_agent_message"), 2000, multiline=True)
            if reply and not any(a.kind == "assistant" and a.text == reply for a in session.recent):
                add_activity(session, "assistant", reply, row)
            add_activity(session, "status", "Turn failed" if error else "Turn completed", row)
        elif event == "turn_aborted":
            session.state = "interrupted"
            add_activity(session, "status", "Turn interrupted", row)
        elif event in ("user_message", "agent_message"):
            add_message(session, "user" if event == "user_message" else "assistant",
                        safe_text(payload.get("message"), 2000, multiline=True), row)
        elif event == "item_completed":
            item = object_of(payload.get("item"))
            item_type = item.get("type")
            if item_type in ("UserMessage", "AgentMessage"):
                if item.get("phase") in (None, "commentary", "final", "final_answer"):
                    add_message(session, "user" if item_type == "UserMessage" else "assistant",
                                content_text(item.get("content")), row)
            elif item_type in ("CommandExecution", "FileChange", "McpToolCall"):
                label = {"CommandExecution": "Command", "FileChange": "File changes",
                         "McpToolCall": "MCP tool"}[item_type]
                status = safe_text(item.get("status")) or "completed"
                code = item.get("exit_code")
                suffix = f" (exit {code})" if type(code) is int else ""
                add_activity(session, "tool", f"{label}: {status}{suffix}", row)
        elif event == "token_count":
            info = object_of(payload.get("info"))
            usage = object_of(info.get("total_token_usage"))
            total = number(usage.get("total_tokens"))
            if total is not None:
                session.total_tokens = int(total)
            primary = object_of(object_of(payload.get("rate_limits")).get("primary"))
            percent = number(primary.get("used_percent"))
            session.limit_used_percent = percent if percent is not None and percent <= 100 else None


def read_session(path: Path) -> Session:
    """Bound startup reads even for huge logs. Incomplete final records wait."""
    session = Session()
    with path.open("rb") as stream:
        stat = os.fstat(stream.fileno())
        session.updated_at = stat.st_mtime
        first = stream.readline(HEADER_BYTES + 1)
        if len(first) > HEADER_BYTES or not first.endswith(b"\n"):
            return session
        reduce_record(session, decode(first))
        header_end = stream.tell()
        start = max(header_end, stat.st_size - TAIL_BYTES)
        stream.seek(start)
        if start > header_end:
            # We may be in the middle of a UTF-8 character or JSON record.
            stream.readline(TAIL_BYTES)
        data = stream.read(TAIL_BYTES)
        lines = data.split(b"\n")
        for line in lines[:-1]:
            reduce_record(session, decode(line))
    return session


class Monitor:
    def __init__(self, root: Path):
        self.root = root
        self.cache: dict[Path, tuple[tuple, Session]] = {}
        self.warnings: list[str] = []
        self.title_stamp: tuple | None = None
        self.titles: dict[str, str] = {}

    def read_titles(self) -> None:
        path = self.root.parent / "session_index.jsonl"
        try:
            stat = path.stat()
            stamp = (stat.st_ino, stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns)
            if stamp == self.title_stamp:
                return
            with path.open("rb") as stream:
                start = max(0, stat.st_size - HEADER_BYTES)
                stream.seek(start)
                if start:
                    stream.readline(HEADER_BYTES)
                data = stream.read(HEADER_BYTES)
            titles = {}
            for line in data.split(b"\n")[:-1]:
                row = decode(line)
                session_id = safe_text(row.get("id"))
                if session_id:
                    titles[session_id] = safe_text(row.get("thread_name"))
            self.titles, self.title_stamp = titles, stamp
        except FileNotFoundError:
            self.titles, self.title_stamp = {}, None
        except OSError:
            self.warnings.append("Session titles could not be read.")
            self.titles, self.title_stamp = {}, None

    def snapshot(self, *, limit: int = 12, stale_after: float = 120,
                 include_subagents: bool = False, now: float | None = None,
                 preferred_ids: set[str] | None = None) -> list[Session]:
        now = time.time() if now is None else now
        self.warnings = []
        self.read_titles()
        files = []
        if not self.root.is_dir():
            self.warnings.append("Session directory is missing or inaccessible.")
        try:
            # os.walk exposes permission failures rather than silently reporting no sessions.
            for directory, _, names in os.walk(self.root, onerror=self._walk_error):
                for name in names:
                    if not name.endswith(".jsonl"):
                        continue
                    path = Path(directory) / name
                    try:
                        stat = path.stat()
                        if path.is_symlink() or not path.is_file():
                            continue
                        files.append((stat.st_mtime_ns, path, stat))
                    except OSError:
                        self.warnings.append("A session file disappeared or could not be read.")
        except OSError:
            self.warnings.append("Could not scan the session directory.")
        files.sort(key=lambda item: (item[0], str(item[1])), reverse=True)
        # Standard rollout filenames end with the session UUID. Include old pins
        # before applying the recent-session limit, without opening every log.
        preferred_ids = preferred_ids or set()
        preferred = [item for item in files
                     if any(item[1].stem.endswith("-" + sid) for sid in preferred_ids)]
        paths = {item[1] for item in preferred}
        candidates = preferred + [item for item in files[:max(100, limit * 10)] if item[1] not in paths]
        sessions = []
        seen = set()
        retained = {}
        # Bound reads when many subagent or unrecognized records are present.
        for _, path, stat in candidates:
            key = (stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns)
            cached = self.cache.get(path)
            try:
                session = cached[1] if cached and cached[0] == key else read_session(path)
            except OSError:
                self.warnings.append("A session file disappeared or could not be read.")
                continue
            retained[path] = (key, session)
            if not session.id or session.id in seen or (session.subagent and not include_subagents):
                continue
            seen.add(session.id)
            sessions.append(replace(session, stale=now - session.updated_at > stale_after,
                                    title=self.titles.get(session.id, session.title)))
            if len(sessions) >= limit:
                break
        self.cache = retained
        self.warnings = sorted(set(self.warnings))
        return sessions

    def _walk_error(self, _: OSError) -> None:
        self.warnings.append("Some session directories could not be read.")


def render(sessions: list[Session], warnings: list[str], *, width: int = 120,
           now: float | None = None) -> str:
    now = time.time() if now is None else now
    lines = ["OPEN AGENT DECK / CODEX / LINUX", "",
             "Recent recorded sessions | observation only | Ctrl+C to exit", "",
             f"{'LAST STATE':<20} {'PROJECT':<25} {'MODEL':<22} {'AGE':>7} {'TOKENS':>10} {'LIMIT':>7}  ID"]
    for session in sessions:
        state = session.state + (" (stale)" if session.stale else "")
        project = Path(session.project).name or "unknown"
        age = max(0, int(now - session.updated_at))
        age_label = f"{age}s" if age < 60 else f"{age // 60}m"
        tokens = f"{session.total_tokens:,}" if session.total_tokens is not None else "—"
        rate = f"{session.limit_used_percent:g}%" if session.limit_used_percent is not None else "—"
        lines.append(f"{state:<20} {project[:25]:<25} {session.model[:22]:<22} "
                     f"{age_label:>7} {tokens:>10} {rate:>7}  {session.id[:8]}")
    if not sessions:
        lines.append("No recognizable Codex rollout sessions found.")
    lines += ["", "Stale = no file update recently; working is a recorded event, not proof of a live process.",
              "Tokens = recorded session total. Limit = last reported primary window usage, not context fill."]
    lines.extend("Notice: " + warning for warning in warnings)
    return "\n".join(line[:width] for line in lines)


def positive(value: str) -> float:
    parsed = float(value)
    if not math.isfinite(parsed) or parsed <= 0:
        raise argparse.ArgumentTypeError("must be a finite positive number")
    return parsed


def positive_int(value: str) -> int:
    try:
        parsed = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be a positive integer") from exc
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return parsed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sessions-dir", type=Path,
                        default=Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))) / "sessions")
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--once", action="store_true", help="print one snapshot")
    modes.add_argument("--json", action="store_true", help="print one machine-readable snapshot")
    parser.add_argument("--interval", type=positive, default=2, help="refresh seconds (default: 2)")
    parser.add_argument("--stale-after", type=positive, default=120, help="freshness threshold in seconds")
    parser.add_argument("--limit", type=positive_int, default=12)
    parser.add_argument("--include-subagents", action="store_true")
    args = parser.parse_args()
    monitor = Monitor(args.sessions_dir.expanduser())
    watch = sys.stdout.isatty() and not (args.once or args.json)
    try:
        if watch:
            sys.stdout.write("\033[?1049h\033[?25l")
        while True:
            now = time.time()
            sessions = monitor.snapshot(limit=args.limit, stale_after=args.stale_after,
                                        include_subagents=args.include_subagents, now=now)
            if args.json:
                print(json.dumps({"source": "codex-rollout", "observed_at": now,
                                  "warnings": monitor.warnings,
                                  "sessions": [asdict(s) for s in sessions]}, indent=2))
            else:
                size = shutil.get_terminal_size((120, 30))
                output = render(sessions, monitor.warnings, width=size.columns, now=now)
                if watch:
                    output = "\033[H\033[2J" + "\n".join(output.splitlines()[:max(1, size.lines - 1)])
                print(output, flush=True)
            if not watch:
                break
            time.sleep(args.interval)
    except KeyboardInterrupt:
        pass
    except BrokenPipeError:
        return 0
    finally:
        if watch:
            sys.stdout.write("\033[?25h\033[?1049l")
            sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
