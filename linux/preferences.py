"""Deck-only pin/hide preferences. Never writes to Codex's files."""

from __future__ import annotations

import json
import os
from pathlib import Path
import tempfile

from monitor import Session


def default_preferences_path() -> Path:
    return Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "openagentdeck/preferences.json"


class Preferences:
    def __init__(self, path: Path | None):
        self.path = path
        self.pinned: set[str] = set()
        self.hidden: set[str] = set()
        self.warning = ""
        self._document: dict = {}
        self._readable = True
        if path is None:
            return
        try:
            with path.open("rb") as stream:
                raw = stream.read(1024 * 1024 + 1)
            if len(raw) > 1024 * 1024:
                raise ValueError("oversized preferences")
            document = json.loads(raw)
            if not isinstance(document, dict):
                raise ValueError("invalid preferences")
            validated = {}
            for name in ("pinned", "hidden"):
                values = document.get(name, [])
                if not isinstance(values, list) or any(not isinstance(v, str) or not v or len(v) > 512 for v in values):
                    raise ValueError("invalid session IDs")
                validated[name] = set(values)
            self.pinned, self.hidden = validated["pinned"], validated["hidden"]
            self._document = document
        except FileNotFoundError:
            pass
        except (OSError, ValueError, UnicodeDecodeError, RecursionError):
            self._readable = False
            self.warning = "Deck preferences could not be read; existing file left untouched."

    def change(self, session_id: str, field: str) -> bool:
        if field not in ("pinned", "hidden") or not session_id:
            return False
        values = set(getattr(self, field))
        values.symmetric_difference_update({session_id})
        return self.save(**{field: values})

    def save(self, *, pinned: set[str] | None = None, hidden: set[str] | None = None) -> bool:
        if not self._readable:
            return False
        pinned = self.pinned if pinned is None else pinned
        hidden = self.hidden if hidden is None else hidden
        document = dict(self._document, pinned=sorted(pinned), hidden=sorted(hidden))
        temp = None
        try:
            if self.path is not None:
                self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=self.path.parent,
                                                 prefix=".preferences-", delete=False) as stream:
                    temp = Path(stream.name)
                    json.dump(document, stream, indent=2)
                    stream.write("\n")
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temp, self.path)
            self.pinned, self.hidden = set(pinned), set(hidden)
            self._document = document
            self.warning = ""
            return True
        except OSError:
            self.warning = "Could not save deck preferences. The change was not applied."
            return False
        finally:
            if temp is not None:
                try:
                    temp.unlink(missing_ok=True)
                except OSError:
                    pass

    def visible(self, rows: list[Session], *, hidden: bool = False) -> list[Session]:
        return sorted((s for s in rows if (s.id in self.hidden) == hidden),
                      key=lambda s: (s.id not in self.pinned, s.stale,
                                     s.state != "working", -s.updated_at, s.id))
