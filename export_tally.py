#!/usr/bin/env python3
"""Export Tally's SavedVariables to a formatted Excel workbook.

The workbook is an .xlsx file, so Google Sheets, Microsoft Excel and
LibreOffice Calc can all open it. By default it is written beside this script;
pass --out to put it somewhere else.

Typical use, from the folder this script lives in:

    python export_tally.py

The script looks for Tally.lua in the usual WoW SavedVariables places. It also
accepts a path to any of these:

    python export_tally.py "C:/Games/World of Warcraft/_retail_"
    python export_tally.py "C:/Games/World of Warcraft/_retail_/Interface/AddOns/Tally"
    python export_tally.py "C:/Games/World of Warcraft/_retail_/WTF/Account/NAME/SavedVariables/Tally.lua"
    python export_tally.py --savedvars "D:/backups/Tally.lua"
    python export_tally.py --out "D:/reports/Tally.xlsx"

The exporter needs openpyxl:

    python -m pip install openpyxl
"""

from __future__ import annotations

import argparse
import json
import os
import re
import string
import subprocess
import sys
from datetime import date, datetime, time
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Set, Tuple

try:
    from openpyxl import Workbook
    from openpyxl.chart import BarChart, LineChart, Reference
    from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
    from openpyxl.utils import get_column_letter
    from openpyxl.worksheet.table import Table, TableStyleInfo
except ImportError:  # handled in main so --help still works without it
    Workbook = None  # type: ignore
    BarChart = LineChart = Reference = None  # type: ignore
    Alignment = Border = Font = PatternFill = Side = None  # type: ignore
    get_column_letter = None  # type: ignore
    Table = TableStyleInfo = None  # type: ignore


# ---------------------------------------------------------------------------
# Small shared values
# ---------------------------------------------------------------------------

SECONDARY_PROFESSIONS = {"Cooking", "Fishing", "First Aid", "Archaeology"}

QUALITY_NAMES = {
    0: "Poor",
    1: "Common",
    2: "Uncommon",
    3: "Rare",
    4: "Epic",
    5: "Legendary",
    6: "Artifact",
    7: "Heirloom",
}

# Colours close to the game's class colours, used for the Class cell only.
CLASS_COLORS = {
    "WARRIOR": "C79C6E",
    "PALADIN": "F58CBA",
    "HUNTER": "ABD473",
    "ROGUE": "FFF569",
    "PRIEST": "FFFFFF",
    "SHAMAN": "0070DE",
    "MAGE": "69CCF0",
    "WARLOCK": "9482C9",
    "DRUID": "FF7D0A",
    "DEATHKNIGHT": "C41F3B",
    "MONK": "00FF96",
    "DEMONHUNTER": "A330C9",
    "EVOKER": "33937F",
}

MONEY_FORMAT = "#,##0.0000"
INT_FORMAT = "#,##0"
DECIMAL_FORMAT = "#,##0.0"
PERCENT_FORMAT = "0.0%"
DATETIME_FORMAT = "yyyy-mm-dd hh:mm"
DATE_FORMAT = "yyyy-mm-dd"


# ---------------------------------------------------------------------------
# Lua table reader
# ---------------------------------------------------------------------------

LONG_OPEN_RE = re.compile(r"\[(=*)\[")
NUMBER_RE = re.compile(r"[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?")
HEX_RE = re.compile(r"([+-]?)0[xX]([0-9A-Fa-f]+)")
IDENT_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


class LuaParseError(ValueError):
    pass


class LuaTableParser:
    """A small reader for the Lua table literals written in SavedVariables.

    It understands the subset WoW uses: quoted and long strings, decimal
    escapes, numbers, booleans, nil and mixed array/map tables. A table whose
    keys are exactly 1..n is returned as a Python list; every other table is a
    dict keyed by its Lua key.
    """

    def __init__(self, text: str, index: int = 0) -> None:
        self.text = text
        self.length = len(text)
        self.i = index

    def _where(self) -> str:
        start = max(0, self.i - 30)
        end = min(self.length, self.i + 60)
        return repr(self.text[start:end])

    def _error(self, message: str) -> None:
        raise LuaParseError(f"{message} at character {self.i}: {self._where()}")

    def _skip(self) -> None:
        text, length = self.text, self.length
        while self.i < length:
            c = text[self.i]
            if c in " \t\r\n":
                self.i += 1
                continue
            if c == "-" and self.i + 1 < length and text[self.i + 1] == "-":
                self.i += 2
                match = LONG_OPEN_RE.match(text, self.i)
                if match:
                    close = "]" + match.group(1) + "]"
                    end = text.find(close, self.i + len(match.group(0)))
                    self.i = length if end < 0 else end + len(close)
                else:
                    end = text.find("\n", self.i)
                    self.i = length if end < 0 else end + 1
                continue
            break

    def _parse_long_string(self) -> Optional[str]:
        match = LONG_OPEN_RE.match(self.text, self.i)
        if not match:
            return None
        close = "]" + match.group(1) + "]"
        start = self.i + len(match.group(0))
        end = self.text.find(close, start)
        if end < 0:
            self._error("unterminated long string")
        value = self.text[start:end]
        self.i = end + len(close)
        # Lua drops one newline immediately after the opening bracket.
        if value.startswith("\r\n"):
            value = value[2:]
        elif value.startswith("\n"):
            value = value[1:]
        return value

    def _parse_string(self) -> str:
        quote = self.text[self.i]
        self.i += 1
        output: List[str] = []
        pending = bytearray()

        def flush() -> None:
            if pending:
                output.append(bytes(pending).decode("utf-8", "replace"))
                pending.clear()

        while self.i < self.length:
            c = self.text[self.i]
            self.i += 1
            if c == quote:
                flush()
                return "".join(output)
            if c != "\\":
                flush()
                output.append(c)
                continue

            if self.i >= self.length:
                self._error("unterminated escape")
            e = self.text[self.i]
            self.i += 1
            if e in "0123456789":
                digits = e
                while (
                    len(digits) < 3
                    and self.i < self.length
                    and self.text[self.i].isdigit()
                ):
                    digits += self.text[self.i]
                    self.i += 1
                pending.append(int(digits, 10) & 0xFF)
                continue
            if e == "x":
                digits = self.text[self.i : self.i + 2]
                if len(digits) == 2 and all(ch in string.hexdigits for ch in digits):
                    pending.append(int(digits, 16))
                    self.i += 2
                else:
                    flush()
                    output.append("x")
                continue
            if e == "z":
                while self.i < self.length and self.text[self.i] in " \t\r\n":
                    self.i += 1
                continue
            if e == "u" and self.i < self.length and self.text[self.i] == "{":
                end = self.text.find("}", self.i + 1)
                if end < 0:
                    self._error("unterminated \\u escape")
                try:
                    flush()
                    output.append(chr(int(self.text[self.i + 1 : end], 16)))
                    self.i = end + 1
                except ValueError:
                    self._error("bad \\u escape")
                continue

            flush()
            escapes = {
                "a": "\a",
                "b": "\b",
                "f": "\f",
                "n": "\n",
                "r": "\r",
                "t": "\t",
                "v": "\v",
                "\\": "\\",
                '"': '"',
                "'": "'",
                "\n": "\n",
            }
            output.append(escapes.get(e, e))

        self._error("unterminated string")

    def _parse_number(self) -> Any:
        hex_match = HEX_RE.match(self.text, self.i)
        if hex_match:
            sign = -1 if hex_match.group(1) == "-" else 1
            self.i = hex_match.end()
            return sign * int(hex_match.group(2), 16)
        match = NUMBER_RE.match(self.text, self.i)
        if not match:
            self._error("bad number")
        token = match.group(0)
        self.i = match.end()
        if any(ch in token for ch in ".eE"):
            return float(token)
        return int(token)

    def _parse_value(self) -> Any:
        self._skip()
        if self.i >= self.length:
            self._error("unexpected end of file")
        c = self.text[self.i]
        if c == "{":
            return self._parse_table()
        if c in "\"'":
            return self._parse_string()
        if c == "[":
            long_value = self._parse_long_string()
            if long_value is not None:
                return long_value
        if c in "+-." or c.isdigit():
            return self._parse_number()
        if c.isalpha() or c == "_":
            match = IDENT_RE.match(self.text, self.i)
            if not match:
                self._error("bad identifier")
            word = match.group(0)
            self.i = match.end()
            if word == "true":
                return True
            if word == "false":
                return False
            if word == "nil":
                return None
            self._error(f"unexpected identifier {word!r}")
        self._error(f"unexpected value starting with {c!r}")

    def _parse_table(self) -> Any:
        if self.text[self.i] != "{":
            self._error("expected {")
        self.i += 1
        values: Dict[Any, Any] = {}
        next_index = 1

        while True:
            self._skip()
            if self.i >= self.length:
                self._error("unterminated table")
            c = self.text[self.i]
            if c == "}":
                self.i += 1
                break
            if c in ",;":
                self.i += 1
                continue

            key: Any = None
            is_long_string = c == "[" and LONG_OPEN_RE.match(self.text, self.i) is not None
            if c == "[" and not is_long_string:
                self.i += 1
                key = self._parse_value()
                self._skip()
                if self.i >= self.length or self.text[self.i] != "]":
                    self._error("expected ] after table key")
                self.i += 1
                self._skip()
                if self.i >= self.length or self.text[self.i] != "=":
                    self._error("expected = after table key")
                self.i += 1
            else:
                save = self.i
                match = IDENT_RE.match(self.text, self.i)
                if match:
                    after = match.end()
                    while after < self.length and self.text[after] in " \t\r\n":
                        after += 1
                    if after < self.length and self.text[after] == "=":
                        key = match.group(0)
                        self.i = after + 1
                    else:
                        self.i = save

            value = self._parse_value()
            if key is None:
                key = next_index
                next_index += 1
            values[key] = value

        # A pure 1..n integer-keyed table is an array.
        if values and all(isinstance(k, int) for k in values):
            keys = sorted(values)
            if keys == list(range(1, len(keys) + 1)):
                return [values[k] for k in keys]
        return values

    def parse(self) -> Any:
        return self._parse_value()


def read_saved_variables(path: Path) -> Dict[str, Any]:
    text = path.read_text(encoding="utf-8-sig", errors="replace")
    match = re.search(r"(?m)^[ \t]*TallyDB[ \t]*=[ \t]*", text)
    if not match:
        match = re.search(r"\bTallyDB\b[ \t]*=[ \t]*", text)
    if not match:
        match = re.search(
            r"(?m)^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*=[ \t]*", text
        )
    if not match:
        raise LuaParseError("no variable assignment found in the file")

    data = LuaTableParser(text, match.end()).parse()
    if not isinstance(data, dict):
        raise LuaParseError("the saved variable is not a table")
    return data


# ---------------------------------------------------------------------------
# Data helpers
# ---------------------------------------------------------------------------


def as_dict(value: Any) -> Dict[Any, Any]:
    return value if isinstance(value, dict) else {}


def as_list(value: Any) -> List[Any]:
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        return list(value.values())
    return []


def num(value: Any, default: Any = 0) -> Any:
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, (int, float)):
        return value
    if isinstance(value, str):
        try:
            number = float(value.strip())
            return int(number) if number.is_integer() else number
        except ValueError:
            return default
    return default


def text(value: Any, default: str = "") -> str:
    if value is None:
        return default
    if isinstance(value, str):
        cleaned = value
    elif isinstance(value, bool):
        return "yes" if value else "no"
    elif isinstance(value, float) and value.is_integer():
        cleaned = str(int(value))
    else:
        cleaned = str(value)
    # Excel cells cannot carry most control characters. Keep newlines and tabs.
    return re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f]", "", cleaned)


def yes_no(value: Any) -> str:
    if value is None:
        return ""
    return "yes" if value else "no"


def to_datetime(value: Any) -> Optional[datetime]:
    stamp = num(value, None)
    if stamp is None or stamp <= 0:
        return None
    try:
        return datetime.fromtimestamp(stamp)
    except (OverflowError, OSError, ValueError):
        return None


def to_date(value: Any) -> Optional[date]:
    moment = to_datetime(value)
    return moment.date() if moment else None


def gold(value: Any) -> float:
    return num(value, 0) / 10000.0


def duration_text(value: Any) -> str:
    total = int(round(num(value, 0)))
    sign = "-" if total < 0 else ""
    total = abs(total)
    days, remainder = divmod(total, 86400)
    hours, remainder = divmod(remainder, 3600)
    minutes, seconds = divmod(remainder, 60)
    if days:
        return f"{sign}{days}d {hours:02d}:{minutes:02d}:{seconds:02d}"
    return f"{sign}{hours:02d}:{minutes:02d}:{seconds:02d}"


def quality_name(value: Any) -> str:
    number = int(num(value, 0))
    return QUALITY_NAMES.get(number, f"Quality {number}")


def counts_text(mapping: Any, label=str, limit: Optional[int] = None) -> str:
    entries = []
    for key, value in as_dict(mapping).items():
        count = num(value, 0)
        if count > 0:
            entries.append((key, count))
    entries.sort(key=lambda item: (-item[1], str(item[0])))
    if limit is not None:
        entries = entries[:limit]
    return "; ".join(f"{label(key)}: {int(count)}" for key, count in entries)


def json_value(value: Any) -> str:
    if isinstance(value, (dict, list)):
        return json.dumps(value, ensure_ascii=False, sort_keys=True)
    return text(value)


def flatten(prefix: str, value: Any, rows: List[Tuple[str, Any]]) -> None:
    if isinstance(value, dict):
        if not value:
            rows.append((prefix, "{}"))
            return
        for key, child in value.items():
            child_prefix = f"{prefix}.{key}" if prefix else str(key)
            flatten(child_prefix, child, rows)
    elif isinstance(value, list):
        if not value:
            rows.append((prefix, "[]"))
            return
        for index, child in enumerate(value, 1):
            flatten(f"{prefix}[{index}]", child, rows)
    else:
        rows.append((prefix, value))


def record_unit(key: str) -> str:
    lower = key.lower()
    if "gold" in lower or "loot" in lower or "auction" in lower:
        return "copper"
    if "session" in lower and "level" not in lower:
        return "seconds"
    if "xp" in lower:
        return "XP"
    if "combat" in lower:
        return "kills"
    return ""


# ---------------------------------------------------------------------------
# Locating the SavedVariables file
# ---------------------------------------------------------------------------


def candidates_in(path: Path) -> List[Path]:
    found: List[Path] = []
    if path.is_file():
        return [path]
    if not path.is_dir():
        return found

    for relative in ("Tally.lua", "SavedVariables/Tally.lua"):
        candidate = path / relative
        if candidate.is_file():
            found.append(candidate)
    for pattern in (
        "WTF/Account/*/SavedVariables/Tally.lua",
        "Account/*/SavedVariables/Tally.lua",
        "*/WTF/Account/*/SavedVariables/Tally.lua",
        "*/Account/*/SavedVariables/Tally.lua",
        "*/SavedVariables/Tally.lua",
    ):
        found.extend(path.glob(pattern))
    return found


def game_root_for_addon(addon: Path) -> Optional[Path]:
    parts = list(addon.parts)
    lowered = [part.lower() for part in parts]
    if "interface" in lowered and "addons" in lowered:
        index = lowered.index("interface")
        if index > 0:
            return Path(*parts[:index])
    return None


def common_wow_roots() -> List[Path]:
    roots: List[Path] = []
    env_root = os.environ.get("WOW_ROOT")
    if env_root:
        roots.append(Path(env_root))
    home = Path.home()
    roots.extend(
        [
            home / "Games" / "World of Warcraft",
            home / "World of Warcraft",
            Path("C:/Program Files (x86)/World of Warcraft"),
            Path("C:/Program Files/World of Warcraft"),
            Path("C:/Games/World of Warcraft"),
            Path("D:/Games/World of Warcraft"),
            Path("E:/Games/World of Warcraft"),
            Path("F:/Games/World of Warcraft"),
            Path("G:/Games/World of Warcraft"),
            Path("H:/Games/World of Warcraft"),
        ]
    )
    return roots


def _select_candidates(found: List[Path], account: Optional[str]) -> List[Path]:
    unique: Dict[str, Path] = {}
    for path in found:
        try:
            resolved = path.expanduser().resolve()
        except OSError:
            continue
        if resolved.is_file() and resolved.name.lower() == "tally.lua":
            if account:
                parent_account = resolved.parent.parent.name
                if parent_account.lower() != account.lower():
                    continue
            unique[str(resolved)] = resolved

    return sorted(
        unique.values(), key=lambda item: item.stat().st_mtime, reverse=True
    )


def find_saved_variables(
    script_dir: Path,
    explicit: Optional[str],
    addon: Optional[str],
    account: Optional[str],
) -> Tuple[Path, List[Path]]:
    # An explicit file or folder is a request for that exact source, so it is
    # never mixed with the automatic search. This matters when several game
    # clients keep their own Tally.lua.
    if explicit:
        explicit_path = Path(explicit).expanduser()
        if explicit_path.is_file():
            resolved = explicit_path.resolve()
            return resolved, [resolved]
        found = candidates_in(explicit_path)
        root = game_root_for_addon(explicit_path)
        if root:
            found.extend(candidates_in(root))
        candidates = _select_candidates(found, account)
        if not candidates:
            raise FileNotFoundError(
                f"No Tally.lua found at or under {explicit_path}. Pass the "
                "SavedVariables file itself, a game folder, or an installed addon folder."
            )
        return candidates[0], candidates

    found: List[Path] = []
    if addon:
        addon_path = Path(addon).expanduser()
        found.extend(candidates_in(addon_path))
        root = game_root_for_addon(addon_path)
        if root:
            found.extend(candidates_in(root))
        candidates = _select_candidates(found, account)
        if not candidates:
            raise FileNotFoundError(
                f"No Tally.lua found for the addon at {addon_path}. Pass the "
                "installed addon folder (inside Interface/AddOns) or the game folder."
            )
        return candidates[0], candidates

    # Prefer the game the script itself sits in. A copy placed in the addon
    # folder should read that client's WTF, not whichever SavedVariables was
    # written most recently on the machine.
    local: List[Path] = []
    local.extend(candidates_in(script_dir))
    root = game_root_for_addon(script_dir)
    if root:
        local.extend(candidates_in(root))
    for parent in script_dir.parents:
        if (parent / "Tally.toc").is_file():
            parent_root = game_root_for_addon(parent)
            if parent_root:
                local.extend(candidates_in(parent_root))
            break

    local_candidates = _select_candidates(local, account)
    if local_candidates:
        return local_candidates[0], local_candidates

    for root in common_wow_roots():
        if root.is_dir():
            found.extend(candidates_in(root))

    candidates = _select_candidates(found, account)
    if not candidates:
        raise FileNotFoundError(
            "Could not find Tally.lua. Pass the SavedVariables file, the addon "
            "folder, or the game folder as an argument, for example:\n"
            '  python export_tally.py "C:/Games/World of Warcraft/_retail_"'
        )
    return candidates[0], candidates


# ---------------------------------------------------------------------------
# Formatting helpers
# ---------------------------------------------------------------------------

if Workbook is not None:
    HEADER_FILL = PatternFill("solid", fgColor="1F3864")
    HEADER_FONT = Font(bold=True, color="FFFFFF", size=11)
    HEADER_ALIGNMENT = Alignment(horizontal="left", vertical="center", wrap_text=True)
    BODY_ALIGNMENT = Alignment(vertical="top", wrap_text=False)
    WRAP_ALIGNMENT = Alignment(vertical="top", wrap_text=True)
    SECTION_FILL = PatternFill("solid", fgColor="FCE4A6")
    SECTION_FONT = Font(bold=True, color="3B2A00", size=12)
    TITLE_FONT = Font(bold=True, color="FFFFFF", size=20)
    TITLE_FILL = PatternFill("solid", fgColor="1F3864")
    SUBTITLE_FONT = Font(italic=True, color="595959", size=10)
    NOTE_FONT = Font(italic=True, color="7F7F7F", size=10)
    THIN_BORDER = Border(bottom=Side(style="thin", color="D9D9D9"))
else:
    HEADER_FILL = HEADER_FONT = HEADER_ALIGNMENT = BODY_ALIGNMENT = None
    WRAP_ALIGNMENT = SECTION_FILL = SECTION_FONT = TITLE_FONT = TITLE_FILL = None
    SUBTITLE_FONT = NOTE_FONT = THIN_BORDER = None


def safe_sheet_title(name: str) -> str:
    cleaned = re.sub(r"[\[\]:*?/\\]", " ", name)
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    return (cleaned or "Sheet")[:31]


class Exporter:
    def __init__(self, workbook: Any, use_tables: bool = True) -> None:
        self.workbook = workbook
        self.use_tables = use_tables
        self.summaries: List[Tuple[str, int, str]] = []
        self.table_names: Set[str] = set()

    def _table_name(self, sheet_name: str) -> str:
        base = re.sub(r"[^A-Za-z0-9_]", "", sheet_name) or "Sheet"
        if not base[0].isalpha():
            base = "T" + base
        base = base[:30]
        candidate = base + "Table"
        suffix = 2
        while candidate in self.table_names:
            candidate = f"{base}Table{suffix}"
            suffix += 1
        self.table_names.add(candidate)
        return candidate

    def add_sheet(
        self,
        name: str,
        headers: Sequence[str],
        rows: Sequence[Sequence[Any]],
        description: str,
        money: Iterable[str] = (),
        dates: Iterable[str] = (),
        date_only: Iterable[str] = (),
        ints: Iterable[str] = (),
        percents: Iterable[str] = (),
        decimals: Iterable[str] = (),
        wrap: Iterable[str] = (),
        widths: Optional[Dict[str, int]] = None,
        tab_color: Optional[str] = None,
    ) -> Any:
        money_set, date_set = set(money), set(dates)
        date_only_set = set(date_only)
        int_set, percent_set, decimal_set = set(ints), set(percents), set(decimals)
        wrap_set = set(wrap)
        headers = [text(header, f"Column {index + 1}") for index, header in enumerate(headers)]
        # Excel tables need unique, non-empty headers.
        seen: Dict[str, int] = {}
        unique_headers: List[str] = []
        for header in headers:
            count = seen.get(header, 0) + 1
            seen[header] = count
            unique_headers.append(header if count == 1 else f"{header} ({count})")
        headers = unique_headers

        sheet = self.workbook.create_sheet(safe_sheet_title(name))
        for column, header in enumerate(headers, 1):
            cell = sheet.cell(row=1, column=column, value=header)
            cell.fill = HEADER_FILL
            cell.font = HEADER_FONT
            cell.alignment = HEADER_ALIGNMENT
            cell.border = THIN_BORDER
        sheet.row_dimensions[1].height = 24

        for row_index, row in enumerate(rows, 2):
            for column, value in enumerate(row, 1):
                header = headers[column - 1]
                cell = sheet.cell(row=row_index, column=column, value=value)
                cell.alignment = WRAP_ALIGNMENT if header in wrap_set else BODY_ALIGNMENT
                if header in money_set and isinstance(value, (int, float)):
                    cell.number_format = MONEY_FORMAT
                elif header in date_only_set and isinstance(value, datetime):
                    cell.number_format = DATE_FORMAT
                elif header in date_set and isinstance(value, datetime):
                    cell.number_format = DATETIME_FORMAT
                elif header in percent_set and isinstance(value, (int, float)):
                    cell.number_format = PERCENT_FORMAT
                elif header in int_set and isinstance(value, (int, float)):
                    cell.number_format = INT_FORMAT
                elif header in decimal_set and isinstance(value, (int, float)):
                    cell.number_format = DECIMAL_FORMAT

        widths = widths or {}
        for column, header in enumerate(headers, 1):
            if header in widths:
                width = widths[header]
            else:
                longest = len(header)
                for row in rows[:400]:
                    value = row[column - 1] if column - 1 < len(row) else None
                    if isinstance(value, datetime):
                        length = 16
                    elif isinstance(value, float):
                        length = len(f"{value:,.2f}")
                    elif value is None:
                        length = 0
                    else:
                        length = len(str(value))
                    longest = max(longest, length)
                width = min(max(9, longest + 2), 55)
            sheet.column_dimensions[get_column_letter(column)].width = width

        if rows:
            sheet.freeze_panes = "A2"
            last_column = get_column_letter(len(headers))
            last_row = len(rows) + 1
            if self.use_tables:
                table = Table(
                    displayName=self._table_name(sheet.title),
                    ref=f"A1:{last_column}{last_row}",
                )
                table.tableStyleInfo = TableStyleInfo(
                    name="TableStyleMedium2",
                    showFirstColumn=False,
                    showLastColumn=False,
                    showRowStripes=True,
                    showColumnStripes=False,
                )
                sheet.add_table(table)
            else:
                sheet.auto_filter.ref = f"A1:{last_column}{last_row}"
        else:
            note = sheet.cell(row=2, column=1, value="No data recorded yet.")
            note.font = NOTE_FONT

        if tab_color:
            sheet.sheet_properties.tabColor = tab_color

        # Print setup: landscape, with the header row repeated. The workbook is
        # mainly for the screen, but this keeps a printed copy readable.
        sheet.page_setup.orientation = "landscape"
        sheet.print_title_rows = "1:1"
        if rows:
            sheet.sheet_properties.pageSetUpPr.fitToPage = False

        self.summaries.append((sheet.title, len(rows), description))
        return sheet


# ---------------------------------------------------------------------------
# Character profiles
# ---------------------------------------------------------------------------


def build_profile(key: str, char: Dict[str, Any]) -> Dict[str, Any]:
    played = as_dict(char.get("played"))
    gold_store = as_dict(char.get("gold"))
    income = as_dict(gold_store.get("income"))
    expenses = as_dict(gold_store.get("expenses"))
    unclassified = as_dict(gold_store.get("unclassified"))
    sessions = as_dict(char.get("sessions"))
    history = as_list(sessions.get("history"))
    current_session = as_dict(sessions.get("current"))
    combat = as_dict(char.get("combat"))
    explore = as_dict(char.get("explore"))
    loot = as_dict(char.get("loot"))
    professions = as_dict(char.get("professions"))
    social = as_dict(char.get("social"))
    milestones = as_dict(char.get("milestones"))
    records = as_dict(char.get("records"))
    fishing = as_dict(char.get("fishing"))
    gathering = as_dict(char.get("gathering"))
    ah = as_dict(char.get("ah"))
    xp = as_dict(char.get("xp"))

    name = text(char.get("name"), key.split("-", 1)[0])
    realm = text(char.get("realm"), "")
    created_ts = num(char.get("created"), 0)

    seen_values = [
        num(played.get("at"), 0),
        num(gold_store.get("balanceAt"), 0),
        num(explore.get("distanceAt"), 0),
    ]
    for session in history:
        if isinstance(session, dict):
            seen_values.append(num(session.get("lastSeenAt"), 0))
    if current_session:
        seen_values.append(num(current_session.get("lastSeenAt"), 0))
    last_seen_ts = max([value for value in seen_values if value > 0] or [0])

    session_seconds = num(sessions.get("seconds"), 0)
    longest_session = num(sessions.get("longest"), 0)
    if history:
        longest_session = max(
            [longest_session]
            + [
                num(session.get("seconds"), 0)
                for session in history
                if isinstance(session, dict)
            ]
        )

    skill_list = [
        skill
        for skill in as_list(professions.get("skills"))
        if isinstance(skill, dict) and skill.get("name")
    ]
    skills_by_name = {text(skill.get("name")): skill for skill in skill_list}
    recipes = as_dict(professions.get("recipes"))
    crafts = as_dict(professions.get("crafts"))
    learned = as_dict(professions.get("learned"))
    by_level = as_dict(professions.get("byLevel"))
    profession_names = set(skills_by_name) | set(recipes) | set(crafts) | set(learned)
    for gains in by_level.values():
        for profession, gained in as_dict(gains).items():
            if num(gained, 0) > 0:
                profession_names.add(text(profession))

    recipes_count = 0
    for profession in profession_names:
        book = as_dict(recipes.get(profession))
        recipes_count += len(as_list(book.get("list")))
        if not book.get("list"):
            recipes_count += len(as_dict(book.get("items"))) or len(as_dict(book.get("ids")))
    crafts_count = sum(num(value, 0) for value in crafts.values())

    crafted_by_profession: Dict[str, Tuple[str, int]] = {}
    for item_name, entry in as_dict(professions.get("crafted")).items():
        entry = as_dict(entry)
        profession = text(entry.get("profession"))
        count = int(num(entry.get("count"), 0))
        if profession and count > (crafted_by_profession.get(profession, ("", 0))[1]):
            crafted_by_profession[profession] = (text(item_name), count)

    fishing_items = as_dict(fishing.get("items"))
    fishing_casts = int(num(fishing.get("casts"), 0))
    fishing_catches = int(num(fishing.get("catches"), 0))

    known_players = as_dict(social.get("known"))
    mail = as_dict(social.get("mail"))
    duels = as_dict(social.get("duels"))
    guild = as_dict(social.get("guild"))

    return {
        "key": key,
        "char": char,
        "name": name,
        "realm": realm,
        "faction": text(char.get("faction"), ""),
        "class": text(char.get("class"), ""),
        "classFile": text(char.get("classFile"), ""),
        "race": text(char.get("race"), ""),
        "level": int(num(char.get("level"), 0)),
        "highLevel": int(num(char.get("highLevel"), 0)),
        "firstLevel": int(num(char.get("firstLevel"), 0)),
        "created": to_datetime(created_ts),
        "lastSeen": to_datetime(last_seen_ts),
        "played": int(num(played.get("total"), session_seconds)),
        "tracked": int(num(char.get("tracked"), 0)),
        "afk": int(num(char.get("afk"), 0)),
        "goldBalance": gold(gold_store.get("balance")),
        "goldIncome": gold(sum(num(value, 0) for value in income.values())),
        "goldExpense": gold(sum(num(value, 0) for value in expenses.values())),
        "goldUnclassified": gold(unclassified.get("net")),
        "unclassifiedCount": int(num(unclassified.get("count"), 0)),
        "sessions": sessions,
        "sessionHistory": history,
        "sessionCurrent": current_session,
        "sessionCount": int(num(sessions.get("count"), 0)),
        "sessionSeconds": int(session_seconds),
        "longestSession": int(longest_session),
        "xp": int(num(xp.get("total"), 0)),
        "quests": int(num(char.get("quests"), 0)),
        "combat": combat,
        "kills": int(num(combat.get("kills"), 0)),
        "deaths": int(num(combat.get("deaths"), 0)),
        "fights": int(num(combat.get("fights"), 0)),
        "combatSeconds": int(num(combat.get("combatSeconds"), 0)),
        "best10": int(num(combat.get("best10"), 0)),
        "bestFight": int(num(combat.get("bestFight"), 0)),
        "killTypes": as_dict(combat.get("killTypes")),
        "killInfo": as_dict(combat.get("killInfo")),
        "deathsByZone": as_dict(combat.get("deathsByZone")),
        "explore": explore,
        "zones": as_dict(explore.get("zones")),
        "dungeons": as_dict(explore.get("dungeons")),
        "distance": num(explore.get("distance"), 0),
        "distanceMounted": num(explore.get("distanceMounted"), 0),
        "distanceOnFoot": num(explore.get("distanceOnFoot"), 0),
        "flightSeconds": int(num(explore.get("flightSeconds"), 0)),
        "flights": int(num(explore.get("flights"), 0)),
        "loot": loot,
        "lootItems": int(num(loot.get("items"), 0)),
        "lootValue": gold(loot.get("value")),
        "pricedItems": int(num(loot.get("pricedItems"), 0)),
        "unpricedItems": int(num(loot.get("unpricedItems"), 0)),
        "lootBest": as_list(loot.get("best")),
        "lootQuality": as_dict(loot.get("quality")),
        "itemCounts": as_dict(loot.get("itemCounts")),
        "professions": professions,
        "currency": as_dict(char.get("currency")),
        "skillsByName": skills_by_name,
        "recipes": recipes,
        "crafts": crafts,
        "learned": learned,
        "professionByLevel": by_level,
        "professionNames": profession_names,
        "recipesCount": recipes_count,
        "craftsCount": int(crafts_count),
        "craftedByProfession": crafted_by_profession,
        "social": social,
        "knownPlayers": known_players,
        "mail": mail,
        "duels": duels,
        "guild": guild,
        "milestones": milestones,
        "firsts": as_dict(milestones.get("firsts")),
        "records": records,
        "fishing": fishing,
        "fishingItems": fishing_items,
        "fishingCasts": fishing_casts,
        "fishingCatches": fishing_catches,
        "fishingKinds": len(fishing_items),
        "gathering": gathering,
        "ah": ah,
    }


# ---------------------------------------------------------------------------
# Sheet builders
# ---------------------------------------------------------------------------


def add_characters(exporter: Exporter, profiles: List[Dict[str, Any]]) -> None:
    headers = [
        "Character",
        "Realm",
        "Faction",
        "Class",
        "Race",
        "Level",
        "Highest level",
        "First level",
        "Played",
        "Played (seconds)",
        "Tracked",
        "Tracked (seconds)",
        "Created",
        "Last seen",
        "Gold balance (g)",
        "Gold earned (g)",
        "Gold spent (g)",
        "Unclassified net (g)",
        "Sessions",
        "Session time",
        "Longest session",
        "XP",
        "Quests",
        "Kills",
        "Deaths",
        "Fights",
        "Combat time",
        "Best 10s",
        "Best fight",
        "Items looted",
        "Loot value (g)",
        "Priced items",
        "Unpriced items",
        "Zones",
        "Dungeons",
        "Distance (m)",
        "Mounted distance (m)",
        "On foot (m)",
        "Flight time",
        "Professions",
        "Recipes",
        "Crafts",
        "Fishing casts",
        "Fishing catches",
        "Fish kinds",
        "Known players",
        "Mail sent",
        "Mail received",
        "Duels won",
        "Duels lost",
        "Guild",
        "Records",
        "Milestones",
    ]
    rows = []
    for profile in profiles:
        rows.append(
            [
                profile["name"],
                profile["realm"],
                profile["faction"],
                profile["class"],
                profile["race"],
                profile["level"],
                profile["highLevel"],
                profile["firstLevel"],
                duration_text(profile["played"]),
                profile["played"],
                duration_text(profile["tracked"]),
                profile["tracked"],
                profile["created"],
                profile["lastSeen"],
                profile["goldBalance"],
                profile["goldIncome"],
                profile["goldExpense"],
                profile["goldUnclassified"],
                profile["sessionCount"],
                duration_text(profile["sessionSeconds"]),
                duration_text(profile["longestSession"]),
                profile["xp"],
                profile["quests"],
                profile["kills"],
                profile["deaths"],
                profile["fights"],
                duration_text(profile["combatSeconds"]),
                profile["best10"],
                profile["bestFight"],
                profile["lootItems"],
                profile["lootValue"],
                profile["pricedItems"],
                profile["unpricedItems"],
                len(profile["zones"]),
                len(profile["dungeons"]),
                profile["distance"],
                profile["distanceMounted"],
                profile["distanceOnFoot"],
                duration_text(profile["flightSeconds"]),
                len(profile["professionNames"]),
                profile["recipesCount"],
                profile["craftsCount"],
                profile["fishingCasts"],
                profile["fishingCatches"],
                profile["fishingKinds"],
                len(profile["knownPlayers"]),
                int(num(profile["mail"].get("sent"), 0)),
                int(num(profile["mail"].get("received"), 0)),
                int(num(profile["duels"].get("won"), 0)),
                int(num(profile["duels"].get("lost"), 0)),
                text(profile["guild"].get("name"), ""),
                len(profile["records"]),
                len(profile["firsts"]),
            ]
        )
    sheet = exporter.add_sheet(
        "Characters",
        headers,
        rows,
        "One row per character, with the headline figures used throughout Tally.",
        money=[h for h in headers if h.endswith("(g)")],
        dates=["Created", "Last seen"],
        ints=[
            "Level",
            "Highest level",
            "First level",
            "Played (seconds)",
            "Tracked (seconds)",
            "Sessions",
            "XP",
            "Quests",
            "Kills",
            "Deaths",
            "Fights",
            "Best 10s",
            "Best fight",
            "Items looted",
            "Priced items",
            "Unpriced items",
            "Zones",
            "Dungeons",
            "Professions",
            "Recipes",
            "Crafts",
            "Fishing casts",
            "Fishing catches",
            "Fish kinds",
            "Known players",
            "Mail sent",
            "Mail received",
            "Duels won",
            "Duels lost",
            "Records",
            "Milestones",
        ],
        decimals=["Distance (m)", "Mounted distance (m)", "On foot (m)"],
        widths={"Character": 22, "Realm": 20, "Guild": 22},
        tab_color="2F5597",
    )

    # A little class colour on the class cell, and bold names.
    class_column = headers.index("Class") + 1
    name_column = headers.index("Character") + 1
    for row_index, profile in enumerate(profiles, 2):
        name_cell = sheet.cell(row=row_index, column=name_column)
        name_cell.font = Font(bold=True)
        class_cell = sheet.cell(row=row_index, column=class_column)
        colour = CLASS_COLORS.get(profile["classFile"].upper())
        if colour:
            class_cell.font = Font(color=colour, bold=True)
            class_cell.fill = PatternFill("solid", fgColor="1F1F1F")


def add_sessions(exporter: Exporter, profiles: List[Dict[str, Any]]) -> None:
    headers = [
        "Character",
        "Realm",
        "Current",
        "Start",
        "End",
        "Duration",
        "Duration (seconds)",
        "Ended reason",
        "Start level",
        "End level",
        "Levels",
        "XP",
        "Gold start (g)",
        "Gold end (g)",
        "Gold change (g)",
        "Items",
        "Item value (g)",
        "Kills",
        "Fights",
        "Deaths",
        "Combat time",
        "Distance (m)",
        "Mounted distance (m)",
        "Flights",
        "Flight time",
        "Firsts",
        "End zone",
        "Duration known",
        "Ended observed",
        "Reloadable",
    ]
    rows = []
    for profile in profiles:
        sessions = list(profile["sessionHistory"])
        if profile["sessionCurrent"]:
            sessions.append(profile["sessionCurrent"])
        for session in sessions:
            if not isinstance(session, dict):
                continue
            current = session is profile["sessionCurrent"]
            start = to_datetime(session.get("start"))
            end = to_datetime(session.get("stop"))
            seconds = int(num(session.get("seconds"), 0))
            end_level = int(num(session.get("endLevel"), 0))
            levels = int(num(session.get("levels"), 0))
            start_level = int(num(session.get("startLevel"), end_level - levels))
            gold_start = session.get("goldStart")
            gold_end = session.get("goldEnd")
            gold_change = None
            if gold_start is not None and gold_end is not None:
                gold_change = gold(gold_end) - gold(gold_start)
            rows.append(
                [
                    profile["name"],
                    profile["realm"],
                    "yes" if current else "",
                    start,
                    end,
                    duration_text(seconds),
                    seconds,
                    text(session.get("endedReason"), "still open" if current else ""),
                    start_level,
                    end_level,
                    levels,
                    int(num(session.get("xp"), 0)),
                    gold(gold_start) if gold_start is not None else None,
                    gold(gold_end) if gold_end is not None else None,
                    gold_change,
                    int(num(session.get("items"), 0)),
                    gold(session.get("itemValue")),
                    int(num(session.get("kills"), 0)),
                    int(num(session.get("fights"), 0)),
                    int(num(session.get("deaths"), 0)),
                    duration_text(session.get("combatSeconds")),
                    num(session.get("distance"), 0),
                    num(session.get("distanceMounted"), 0),
                    int(num(session.get("flights"), 0)),
                    duration_text(session.get("flightSeconds")),
                    len(as_list(session.get("firsts"))),
                    text(session.get("endZone"), ""),
                    yes_no(session.get("durationKnown")) if not current else "",
                    yes_no(session.get("endedObserved")) if not current else "",
                    yes_no(session.get("reloadable")),
                ]
            )
    rows.sort(key=lambda row: (row[3] or datetime.min), reverse=True)
    exporter.add_sheet(
        "Sessions",
        headers,
        rows,
        "One row per finished session, plus the session still open at the last save.",
        money=["Gold start (g)", "Gold end (g)", "Gold change (g)", "Item value (g)"],
        dates=["Start", "End"],
        ints=[
            "Duration (seconds)",
            "Start level",
            "End level",
            "Levels",
            "XP",
            "Items",
            "Kills",
            "Fights",
            "Deaths",
            "Flights",
            "Firsts",
        ],
        decimals=["Distance (m)", "Mounted distance (m)"],
        widths={"Ended reason": 16, "End zone": 20},
        tab_color="2A9D8F",
    )


def add_gold_transactions(exporter: Exporter, profiles: List[Dict[str, Any]]) -> None:
    headers = [
        "Character",
        "Realm",
        "Date",
        "Change (g)",
        "Change (copper)",
        "Category",
        "Balance after (g)",
        "Balance after (copper)",
    ]
    rows = []
    for profile in profiles:
        for transaction in as_list(as_dict(profile["char"].get("gold")).get("tx")):
            if not isinstance(transaction, dict):
                continue
            rows.append(
                [
                    profile["name"],
                    profile["realm"],
                    to_datetime(transaction.get("t")),
                    gold(transaction.get("d")),
                    int(num(transaction.get("d"), 0)),
                    text(transaction.get("c"), "unclassified"),
                    gold(transaction.get("b")),
                    int(num(transaction.get("b"), 0)),
                ]
            )
    if not rows:
        return
    rows.sort(key=lambda row: (row[2] or datetime.min), reverse=True)
    exporter.add_sheet(
        "Gold transactions",
        headers,
        rows,
        "The most recent gold changes Tally kept, with the balance after each one.",
        money=["Change (g)", "Balance after (g)"],
        dates=["Date"],
        ints=["Change (copper)", "Balance after (copper)"],
        widths={"Category": 18},
        tab_color="548235",
    )


def add_daily_gold(exporter: Exporter, profiles: List[Dict[str, Any]]) -> None:
    headers = [
        "Character",
        "Realm",
        "Date",
        "Income (g)",
        "Expense (g)",
        "Net (g)",
        "End-of-day balance (g)",
        "Ledger gap",
    ]
    rows = []
    for profile in profiles:
        gold_store = as_dict(profile["char"].get("gold"))
        daily = as_dict(gold_store.get("daily"))
        if not daily:
            continue
        parsed: List[Tuple[date, Dict[str, Any]]] = []
        for key, totals in daily.items():
            try:
                day = datetime.strptime(text(key), "%Y-%m-%d").date()
            except ValueError:
                continue
            parsed.append((day, as_dict(totals)))
        if not parsed:
            continue
        parsed.sort(key=lambda item: item[0], reverse=True)
        created = to_date(profile["char"].get("created"))
        running = num(gold_store.get("balance"), 0)
        balances: Dict[date, float] = {}
        for day, totals in parsed:
            if created is None or day >= created:
                balances[day] = running / 10000.0
            running -= num(totals.get("income"), 0) - num(totals.get("expense"), 0)
        gap = any(value < 0 for value in balances.values())
        for day, totals in parsed:
            if day not in balances:
                continue
            income = gold(totals.get("income"))
            expense = gold(totals.get("expense"))
            rows.append(
                [
                    profile["name"],
                    profile["realm"],
                    datetime.combine(day, time.min),
                    income,
                    expense,
                    income - expense,
                    balances[day],
                    "yes" if gap else "",
                ]
            )
    if not rows:
        return
    rows.sort(key=lambda row: (row[2], row[0].lower()), reverse=True)
    exporter.add_sheet(
        "Daily gold",
        headers,
        rows,
        "One row per character and day, including a balance reconstructed from the current purse.",
        money=["Income (g)", "Expense (g)", "Net (g)", "End-of-day balance (g)"],
        dates=["Date"],
        date_only=["Date"],
        widths={"Ledger gap": 12},
        tab_color="70AD47",
    )


def add_professions(exporter: Exporter, profiles: List[Dict[str, Any]]) -> None:
    headers = [
        "Character",
        "Realm",
        "Profession",
        "Secondary",
        "Rank",
        "Max rank",
        "Rank %",
        "First seen",
        "Last rank change",
        "Last seen",
        "Recipes",
        "Crafts",
        "Most crafted",
        "Most crafted count",
        "Observed",
        "Evidence",
    ]
    rows = []
    for profile in profiles:
        for profession in sorted(profile["professionNames"]):
            skill = as_dict(profile["skillsByName"].get(profession))
            learned = as_dict(profile["learned"].get(profession))
            book = as_dict(profile["recipes"].get(profession))
            rank = num(skill.get("rank"), None)
            max_rank = num(skill.get("maxRank"), None)
            rank_percent = None
            if rank is not None and max_rank:
                rank_percent = rank / max_rank
            first_seen = (
                skill.get("firstAt")
                or skill.get("at")
                or learned.get("at")
                or skill.get("lastSeenAt")
            )
            last_rank_change = skill.get("lastRankAt") or skill.get("updatedAt")
            recipes_count = len(as_list(book.get("list")))
            if not book.get("list"):
                recipes_count = len(as_dict(book.get("items"))) or len(as_dict(book.get("ids")))
            most = profile["craftedByProfession"].get(profession)
            rows.append(
                [
                    profile["name"],
                    profile["realm"],
                    profession,
                    "yes" if profession in SECONDARY_PROFESSIONS else "no",
                    rank,
                    max_rank,
                    rank_percent,
                    to_datetime(first_seen),
                    to_datetime(last_rank_change),
                    to_datetime(skill.get("lastSeenAt")),
                    recipes_count,
                    int(num(profile["crafts"].get(profession), 0)),
                    most[0] if most else "",
                    most[1] if most else None,
                    text(skill.get("observed"), ""),
                    text(skill.get("evidence"), ""),
                ]
            )
    if not rows:
        return
    rows.sort(key=lambda row: (row[0].lower(), row[3], row[2].lower()))
    exporter.add_sheet(
        "Professions",
        headers,
        rows,
        "Profession ranks, recipe counts and crafting totals for each character.",
        dates=["First seen", "Last rank change", "Last seen"],
        ints=["Rank", "Max rank", "Recipes", "Crafts", "Most crafted count"],
        percents=["Rank %"],
        widths={"Profession": 20, "Most crafted": 26},
        tab_color="7030A0",
    )


def add_profession_gains(exporter: Exporter, profiles: List[Dict[str, Any]]) -> None:
    headers = ["Character", "Realm", "Level", "Profession", "Gained"]
    rows = []
    for profile in profiles:
        for level, gains in as_dict(profile["professionByLevel"]).items():
            level_number = int(num(level, 0))
            for profession, gained in as_dict(gains).items():
                amount = int(num(gained, 0))
                if amount > 0:
                    rows.append(
                        [profile["name"], profile["realm"], level_number, text(profession), amount]
                    )
    if not rows:
        return
    rows.sort(key=lambda row: (row[0].lower(), row[2], row[3].lower()))
    exporter.add_sheet(
        "Profession gains",
        headers,
        rows,
        "Live profession skill-ups per character level, from the addon's by-level record.",
        ints=["Level", "Gained"],
        tab_color="9E480E",
    )


def add_fishing(exporter: Exporter, profiles: List[Dict[str, Any]]) -> None:
    summary_headers = [
        "Character",
        "Realm",
        "Casts",
        "Catches",
        "Catch rate",
        "Kinds",
        "Best zone",
        "Best zone catches",
        "Best catch",
        "Best catch value (g)",
        "Best catch count",
        "Best catch zone",
        "Best catch date",
    ]
    summary_rows = []
    detail_headers = [
        "Character",
        "Realm",
        "Item",
        "Item ID",
        "Quality",
        "Count",
        "Unit value (g)",
        "Total value (g)",
        "First caught",
        "Last caught",
        "Zones",
        "Levels",
    ]
    detail_rows = []
    for profile in profiles:
        fishing = profile["fishing"]
        casts = profile["fishingCasts"]
        catches = profile["fishingCatches"]
        items = profile["fishingItems"]
        if not (casts or catches or items):
            continue
        best = as_dict(fishing.get("best"))
        zones = as_dict(fishing.get("zones"))
        best_zone, best_zone_count = None, 0
        for zone, count in zones.items():
            count = num(count, 0)
            if count > best_zone_count:
                best_zone, best_zone_count = text(zone), int(count)
        summary_rows.append(
            [
                profile["name"],
                profile["realm"],
                casts,
                catches,
                (catches / casts) if casts else None,
                len(items),
                best_zone or "",
                best_zone_count or None,
                text(best.get("name"), ""),
                gold(best.get("value")),
                int(num(best.get("count"), 0)),
                text(best.get("zone"), ""),
                to_datetime(best.get("at")),
            ]
        )
        for item_id, entry in items.items():
            entry = as_dict(entry)
            count = int(num(entry.get("count"), 0))
            unit_value = gold(entry.get("unitValue"))
            detail_rows.append(
                [
                    profile["name"],
                    profile["realm"],
                    text(entry.get("name"), f"Item {item_id}"),
                    text(item_id),
                    quality_name(entry.get("quality")),
                    count,
                    unit_value,
                    unit_value * count,
                    to_datetime(entry.get("firstAt")),
                    to_datetime(entry.get("lastAt")),
                    counts_text(entry.get("zones")),
                    counts_text(entry.get("levels"), label=lambda value: f"Level {value}"),
                ]
            )
    if summary_rows:
        summary_rows.sort(key=lambda row: (-row[3], row[0].lower()))
        exporter.add_sheet(
            "Fishing",
            summary_headers,
            summary_rows,
            "Fishing totals per character: casts, catches, kinds and the best catch.",
            money=["Best catch value (g)"],
            dates=["Best catch date"],
            ints=["Casts", "Catches", "Kinds", "Best zone catches", "Best catch count"],
            percents=["Catch rate"],
            widths={"Best catch": 24, "Best zone": 22},
            tab_color="00B0F0",
        )
    if detail_rows:
        detail_rows.sort(key=lambda row: (row[0].lower(), -row[5]))
        exporter.add_sheet(
            "Fishing catches",
            detail_headers,
            detail_rows,
            "Every item pulled out of the water during a Fishing cast.",
            money=["Unit value (g)", "Total value (g)"],
            dates=["First caught", "Last caught"],
            ints=["Count"],
            widths={"Item": 28, "Zones": 40, "Levels": 30},
            wrap=["Zones", "Levels"],
            tab_color="00B0F0",
        )


def add_gathering(exporter: Exporter, profiles: List[Dict[str, Any]]) -> None:
    summary_headers = [
        "Character",
        "Realm",
        "Profession",
        "Gathers",
        "Items",
        "Kinds",
        "Best zone",
        "Best zone items",
        "Best find",
        "Best find value (g)",
    ]
    summary_rows = []
    detail_headers = [
        "Character",
        "Realm",
        "Profession",
        "Item",
        "Item ID",
        "Quality",
        "Count",
        "Unit value (g)",
        "Total value (g)",
        "First",
        "Last",
        "Zones",
        "Levels",
    ]
    detail_rows = []
    level_headers = ["Character", "Realm", "Level", "Profession", "Items"]
    level_rows = []

    for profile in profiles:
        gathering = as_dict(profile.get("gathering"))
        for profession, raw in gathering.items():
            entry = as_dict(raw)
            items = as_dict(entry.get("items"))
            if not items and not entry:
                continue
            gathered = int(num(entry.get("gathered"), 0))
            if gathered <= 0:
                gathered = sum(int(num(as_dict(item).get("count"), 0)) for item in items.values())
            kinds = len(items)
            best_zone, best_zone_count = None, 0
            for zone, count in as_dict(entry.get("zones")).items():
                count = int(num(count, 0))
                if count > best_zone_count:
                    best_zone, best_zone_count = text(zone), count
            best = as_dict(entry.get("best"))
            summary_rows.append(
                [
                    profile["name"],
                    profile["realm"],
                    text(profession),
                    int(num(entry.get("attempts"), 0)),
                    gathered,
                    kinds,
                    best_zone or "",
                    best_zone_count or None,
                    text(best.get("name"), ""),
                    gold(best.get("value")),
                ]
            )
            for item_id, raw_item in items.items():
                item = as_dict(raw_item)
                count = int(num(item.get("count"), 0))
                unit_value = gold(item.get("unitValue"))
                detail_rows.append(
                    [
                        profile["name"],
                        profile["realm"],
                        text(profession),
                        text(item.get("name"), f"Item {item_id}"),
                        text(item_id),
                        quality_name(item.get("quality")),
                        count,
                        unit_value,
                        unit_value * count,
                        to_datetime(item.get("firstAt")),
                        to_datetime(item.get("lastAt")),
                        counts_text(item.get("zones")),
                        counts_text(item.get("levels"), label=lambda value: f"Level {value}"),
                    ]
                )
            for level, count in as_dict(entry.get("levels")).items():
                count = int(num(count, 0))
                if count > 0:
                    level_rows.append(
                        [
                            profile["name"],
                            profile["realm"],
                            int(num(level, 0)),
                            text(profession),
                            count,
                        ]
                    )

    if summary_rows:
        summary_rows.sort(key=lambda row: (row[0].lower(), row[2].lower()))
        exporter.add_sheet(
            "Gathering",
            summary_headers,
            summary_rows,
            "Mining, Herbalism and Skinning totals per character: gathers, items and the best find.",
            money=["Best find value (g)"],
            ints=["Gathers", "Items", "Kinds", "Best zone items"],
            widths={"Best find": 26, "Best zone": 24},
            tab_color="70AD47",
        )
    if detail_rows:
        detail_rows.sort(key=lambda row: (row[0].lower(), row[2].lower(), -row[6]))
        exporter.add_sheet(
            "Gathering items",
            detail_headers,
            detail_rows,
            "Every ore, herb and leather item attributed to a successful gather.",
            money=["Unit value (g)", "Total value (g)"],
            dates=["First", "Last"],
            ints=["Count"],
            widths={"Item": 28, "Zones": 40, "Levels": 30},
            wrap=["Zones", "Levels"],
            tab_color="70AD47",
        )
    if level_rows:
        level_rows.sort(key=lambda row: (row[0].lower(), row[2], row[3].lower()))
        exporter.add_sheet(
            "Gathering by level",
            level_headers,
            level_rows,
            "Gathered item counts by character level and profession.",
            ints=["Level", "Items"],
            tab_color="70AD47",
        )


def add_merchants_favor(exporter: Exporter, profiles: List[Dict[str, Any]]) -> None:
    summary_headers = [
        "Character",
        "Realm",
        "Balance",
        "Starting",
        "Earned",
        "Spent",
        "Best gain",
        "Best gain level",
        "Best gain date",
        "First seen",
        "Last seen",
    ]
    summary_rows = []
    level_headers = ["Character", "Realm", "Level", "Earned", "Spent", "Net"]
    level_rows = []

    for profile in profiles:
        currency = as_dict(profile.get("currency"))
        entry = as_dict(currency.get(3402) or currency.get("3402"))
        if not entry:
            continue
        balance = int(num(entry.get("balance"), 0))
        starting = int(num(entry.get("starting"), 0))
        earned = int(num(entry.get("earned"), 0))
        spent = int(num(entry.get("spent"), 0))
        if not entry.get("firstAt") and balance == 0 and earned == 0 and spent == 0:
            continue
        summary_rows.append(
            [
                profile["name"],
                profile["realm"],
                balance,
                starting,
                earned,
                spent,
                int(num(entry.get("bestGain"), 0)),
                int(num(entry.get("bestGainLevel"), 0)),
                to_datetime(entry.get("bestGainAt")),
                to_datetime(entry.get("firstAt")),
                to_datetime(entry.get("lastAt")),
            ]
        )
        for level, raw in as_dict(entry.get("byLevel")).items():
            row = as_dict(raw)
            level_earned = int(num(row.get("earned"), 0))
            level_spent = int(num(row.get("spent"), 0))
            if level_earned or level_spent:
                level_rows.append(
                    [
                        profile["name"],
                        profile["realm"],
                        int(num(level, 0)),
                        level_earned,
                        level_spent,
                        level_earned - level_spent,
                    ]
                )

    if summary_rows:
        summary_rows.sort(key=lambda row: (row[0].lower(), row[1].lower()))
        exporter.add_sheet(
            "Merchant's Favor",
            summary_headers,
            summary_rows,
            "Merchant's Favor (currency 3402) per character: balance, starting balance, earned, spent and best gain.",
            ints=["Balance", "Starting", "Earned", "Spent", "Best gain", "Best gain level"],
            dates=["Best gain date", "First seen", "Last seen"],
            tab_color="D4A017",
        )
    if level_rows:
        level_rows.sort(key=lambda row: (row[0].lower(), row[2]))
        exporter.add_sheet(
            "Merchant's Favor by level",
            level_headers,
            level_rows,
            "Merchant's Favor earned and spent by character level.",
            ints=["Level", "Earned", "Spent", "Net"],
            tab_color="D4A017",
        )


def collect_quality_ids(profiles: List[Dict[str, Any]]) -> Dict[str, int]:
    quality: Dict[str, int] = {}

    def note(item_id: Any, value: Any) -> None:
        key = text(item_id)
        if key and key not in quality and value is not None:
            quality[key] = int(num(value, 0))

    for profile in profiles:
        for entry in profile["lootBest"]:
            entry = as_dict(entry)
            note(entry.get("id"), entry.get("quality"))
        for entry in as_list(profile["loot"].get("recent")):
            entry = as_dict(entry)
            note(entry.get("id"), entry.get("quality"))
        for item_id, entry in profile["fishingItems"].items():
            entry = as_dict(entry)
            note(item_id, entry.get("quality"))
        for entry in as_dict(profile["professions"].get("crafted")).values():
            entry = as_dict(entry)
            note(entry.get("itemID"), entry.get("quality"))
        for entry in as_list(profile["ah"].get("buys")):
            entry = as_dict(entry)
            note(entry.get("id"), entry.get("quality"))
    return quality


def add_loot(exporter: Exporter, profiles: List[Dict[str, Any]]) -> None:
    quality_by_id = collect_quality_ids(profiles)

    item_headers = ["Character", "Realm", "Item", "Item ID", "Count", "Quality"]
    item_rows = []
    for profile in profiles:
        for item_id, entry in profile["itemCounts"].items():
            entry = as_dict(entry)
            count = int(num(entry.get("count"), 0))
            if count <= 0:
                continue
            item_rows.append(
                [
                    profile["name"],
                    profile["realm"],
                    text(entry.get("name"), f"Item {item_id}"),
                    text(item_id),
                    count,
                    quality_name(quality_by_id[text(item_id)]) if text(item_id) in quality_by_id else "",
                ]
            )
    if item_rows:
        item_rows.sort(key=lambda row: (row[0].lower(), -row[4]))
        exporter.add_sheet(
            "Loot items",
            item_headers,
            item_rows,
            "Every item Tally saw looted, with the number of times it was picked up.",
            ints=["Count"],
            widths={"Item": 30},
            tab_color="ED7D31",
        )

    best_headers = [
        "Character",
        "Realm",
        "Date",
        "Item",
        "Item ID",
        "Quality",
        "Count",
        "Value (g)",
        "Unit value (g)",
    ]
    best_rows = []
    for profile in profiles:
        for entry in profile["lootBest"]:
            entry = as_dict(entry)
            count = int(num(entry.get("count"), 0))
            value = gold(entry.get("value"))
            best_rows.append(
                [
                    profile["name"],
                    profile["realm"],
                    to_datetime(entry.get("at")),
                    text(entry.get("name"), "?"),
                    text(entry.get("id")),
                    quality_name(entry.get("quality")),
                    count,
                    value,
                    value / count if count else None,
                ]
            )
    if best_rows:
        best_rows.sort(key=lambda row: row[7], reverse=True)
        exporter.add_sheet(
            "Best finds",
            best_headers,
            best_rows,
            "The best single finds Tally recorded, by vendor value.",
            money=["Value (g)", "Unit value (g)"],
            dates=["Date"],
            ints=["Count"],
            widths={"Item": 30},
            tab_color="ED7D31",
        )

    quality_headers = ["Character", "Realm", "Quality", "Quality number", "Items"]
    quality_rows = []
    for profile in profiles:
        for quality, count in profile["lootQuality"].items():
            count = int(num(count, 0))
            if count <= 0:
                continue
            quality_rows.append(
                [
                    profile["name"],
                    profile["realm"],
                    quality_name(quality),
                    int(num(quality, 0)),
                    count,
                ]
            )
    if quality_rows:
        quality_rows.sort(key=lambda row: (row[0].lower(), row[3]))
        exporter.add_sheet(
            "Loot quality",
            quality_headers,
            quality_rows,
            "Loot counts grouped by item quality.",
            ints=["Quality number", "Items"],
            tab_color="ED7D31",
        )


def add_combat(exporter: Exporter, profiles: List[Dict[str, Any]]) -> None:
    kill_headers = ["Character", "Realm", "Creature", "Kills", "First", "Last", "Zones"]
    kill_rows = []
    for profile in profiles:
        info_by_name = profile["killInfo"]
        creatures = set(profile["killTypes"]) | set(info_by_name)
        for creature in creatures:
            count = int(num(profile["killTypes"].get(creature), 0))
            info = as_dict(info_by_name.get(creature))
            if count <= 0 and not info:
                continue
            zones = counts_text(info.get("zones"))
            kill_rows.append(
                [
                    profile["name"],
                    profile["realm"],
                    text(creature),
                    count,
                    to_datetime(info.get("first")),
                    to_datetime(info.get("last") or info.get("updatedAt")),
                    zones,
                ]
            )
    if kill_rows:
        kill_rows.sort(key=lambda row: (row[0].lower(), -row[3]))
        exporter.add_sheet(
            "Kills",
            kill_headers,
            kill_rows,
            "Kills by creature, with the first and last time each was killed.",
            dates=["First", "Last"],
            ints=["Kills"],
            widths={"Creature": 30, "Zones": 30},
            wrap=["Zones"],
            tab_color="C00000",
        )

    death_headers = ["Character", "Realm", "Zone", "Deaths"]
    death_rows = []
    for profile in profiles:
        for zone, count in profile["deathsByZone"].items():
            count = int(num(count, 0))
            if count > 0:
                death_rows.append([profile["name"], profile["realm"], text(zone), count])
    if death_rows:
        death_rows.sort(key=lambda row: (row[0].lower(), -row[3]))
        exporter.add_sheet(
            "Deaths",
            death_headers,
            death_rows,
            "Deaths grouped by the zone they happened in.",
            ints=["Deaths"],
            widths={"Zone": 28},
            tab_color="C00000",
        )


def add_explore(exporter: Exporter, profiles: List[Dict[str, Any]]) -> None:
    headers = [
        "Character",
        "Realm",
        "Kind",
        "Zone",
        "Visits",
        "Runs",
        "Bosses",
        "Time",
        "Time (seconds)",
        "First",
        "Last",
        "Level",
    ]
    rows = []
    for profile in profiles:
        for zone, entry in profile["zones"].items():
            entry = as_dict(entry)
            seconds = int(num(entry.get("seconds"), 0))
            rows.append(
                [
                    profile["name"],
                    profile["realm"],
                    "Zone",
                    text(zone),
                    int(num(entry.get("visits"), 0)),
                    None,
                    None,
                    duration_text(seconds),
                    seconds,
                    to_datetime(entry.get("first")),
                    to_datetime(entry.get("last") or entry.get("lastSeenAt")),
                    int(num(entry.get("level"), 0)),
                ]
            )
        for dungeon, entry in profile["dungeons"].items():
            entry = as_dict(entry)
            seconds = int(num(entry.get("seconds"), 0))
            rows.append(
                [
                    profile["name"],
                    profile["realm"],
                    "Dungeon",
                    text(dungeon),
                    int(num(entry.get("visits") or entry.get("runs") or 0, 0)),
                    int(num(entry.get("runs"), 0)),
                    int(num(entry.get("bosses"), 0)),
                    duration_text(seconds),
                    seconds,
                    to_datetime(entry.get("first")),
                    to_datetime(entry.get("last") or entry.get("lastSeenAt")),
                    int(num(entry.get("level"), 0)),
                ]
            )
    if not rows:
        return
    rows.sort(key=lambda row: (row[0].lower(), row[2], -row[8]))
    exporter.add_sheet(
        "Zones",
        headers,
        rows,
        "Time spent in each zone and instance, with visits and first/last seen dates.",
        dates=["First", "Last"],
        ints=["Visits", "Runs", "Bosses", "Time (seconds)", "Level"],
        widths={"Zone": 28},
        tab_color="548235",
    )


def add_milestones(exporter: Exporter, profiles: List[Dict[str, Any]]) -> None:
    headers = [
        "Character",
        "Realm",
        "Kind",
        "Name",
        "Date",
        "Level",
        "Zone",
        "Detail",
        "How",
        "Observed",
        "Evidence",
        "Item ID",
        "Quality",
    ]
    rows = []

    def add(profile: Dict[str, Any], kind: str, entry: Any, detail: str = "") -> None:
        if not isinstance(entry, dict) or not entry:
            return
        # Empty tables are common in old saves (e.g. firstWeapon = { Wands = {} });
        # a row with nothing but its kind is noise.
        if not any(
            entry.get(key) not in (None, "", {}, [])
            for key in ("name", "item", "at", "zone", "itemID", "value", "level")
        ):
            return
        entry_name = entry.get("name") or entry.get("item") or kind
        rows.append(
            [
                profile["name"],
                profile["realm"],
                kind,
                text(entry_name),
                to_datetime(entry.get("at")),
                int(num(entry.get("level"), 0)) or None,
                text(entry.get("zone") or (entry_name if kind == "zone" else ""), ""),
                detail,
                text(entry.get("how"), ""),
                text(entry.get("observed"), ""),
                text(entry.get("evidence"), ""),
                text(entry.get("itemID"), ""),
                quality_name(entry.get("quality")) if entry.get("quality") is not None else "",
            ]
        )

    for profile in profiles:
        milestones = profile["milestones"]
        for kind, entry in as_dict(milestones.get("firsts")).items():
            add(profile, text(kind), entry)
        for entry in as_list(profile["explore"].get("recentFirsts")):
            add(profile, "zone", entry)
        add(profile, "group", milestones.get("firstGroup"))
        add(profile, "riding", milestones.get("riding"))
        for weapon_type, entry in as_dict(milestones.get("firstWeapon")).items():
            add(profile, "weapon", entry, f"Type: {weapon_type}")
        for slot, entry in as_dict(milestones.get("firstSlot")).items():
            add(profile, "equipment slot", entry, f"Slot: {slot}")
        for class_name, entry in as_dict(milestones.get("firstGroupByClass")).items():
            add(profile, "group by class", entry, f"Class: {class_name}")

    if not rows:
        return
    rows.sort(key=lambda row: (row[0].lower(), row[4] or datetime.min))
    exporter.add_sheet(
        "Milestones",
        headers,
        rows,
        "Character firsts: zones, groups, weapons, equipment, riding and the main milestone list.",
        dates=["Date"],
        ints=["Level"],
        widths={"Name": 26, "Detail": 22, "Zone": 26},
        tab_color="BF8F00",
    )


def add_records(exporter: Exporter, profiles: List[Dict[str, Any]]) -> None:
    headers = [
        "Character",
        "Realm",
        "Record",
        "Value",
        "Unit",
        "Value (g)",
        "Date",
        "Previous",
        "Observed",
        "Event",
    ]
    rows = []
    for profile in profiles:
        for key, entry in profile["records"].items():
            if not isinstance(entry, dict):
                continue
            value = num(entry.get("value"), 0)
            unit = record_unit(text(key))
            rows.append(
                [
                    profile["name"],
                    profile["realm"],
                    text(key),
                    value,
                    unit,
                    gold(value) if unit == "copper" else None,
                    to_datetime(entry.get("at")),
                    num(entry.get("previous"), None),
                    text(entry.get("observed"), ""),
                    text(entry.get("event"), ""),
                ]
            )
    if not rows:
        return
    rows.sort(key=lambda row: (row[2].lower(), -row[3]))
    exporter.add_sheet(
        "Records",
        headers,
        rows,
        "Personal bests stored by Tally, with the value and when it was set.",
        money=["Value (g)"],
        dates=["Date"],
        widths={"Record": 30, "Observed": 14},
        tab_color="7F7F7F",
    )


def add_auction(exporter: Exporter, profiles: List[Dict[str, Any]]) -> None:
    summary_headers = [
        "Character",
        "Realm",
        "Posted",
        "Sold",
        "Units sold",
        "Sold for (g)",
        "Bought units",
        "Spent (g)",
        "Cut (g)",
        "Expired",
        "Cancelled",
        "Received (g)",
        "Items tracked",
        "Best sale",
        "Best sale price (g)",
        "Best sale net (g)",
        "Best buy",
        "Best buy (g)",
    ]
    summary_rows = []
    item_headers = [
        "Character",
        "Realm",
        "Item",
        "Item ID",
        "Units",
        "Bought",
        "Sales",
        "Income (g)",
        "Cost (g)",
        "Cut (g)",
        "Deposit (g)",
        "Received (g)",
        "Best (g)",
        "Best date",
        "Last",
        "Min unit (g)",
        "Max unit (g)",
        "Quality",
    ]
    item_rows = []
    activity_headers = [
        "Character",
        "Realm",
        "Date",
        "Type",
        "Item",
        "Item ID",
        "Units",
        "Price (g)",
        "Buyout (g)",
        "Quality",
    ]
    activity_rows = []

    for profile in profiles:
        ah = profile["ah"]
        if not ah:
            continue
        best = as_dict(ah.get("best"))
        best_buy = as_dict(ah.get("bestBuy"))
        items = as_dict(ah.get("items"))
        summary_rows.append(
            [
                profile["name"],
                profile["realm"],
                int(num(ah.get("posted"), 0)),
                int(num(ah.get("sold"), 0)),
                int(num(ah.get("units"), 0)),
                gold(ah.get("soldFor")),
                int(num(ah.get("boughtUnits"), 0)),
                gold(ah.get("spent")),
                gold(ah.get("cut")),
                int(num(ah.get("expired"), 0)),
                int(num(ah.get("cancelled"), 0)),
                gold(ah.get("received")),
                len(items),
                text(best.get("name"), ""),
                gold(best.get("price")) if best else None,
                gold(best.get("net")) if best else None,
                text(best_buy.get("name"), ""),
                gold(best_buy.get("price")) if best_buy else None,
            ]
        )
        for item_name, entry in items.items():
            entry = as_dict(entry)
            item_rows.append(
                [
                    profile["name"],
                    profile["realm"],
                    text(entry.get("name"), text(item_name)),
                    text(entry.get("id"), ""),
                    int(num(entry.get("units"), 0)),
                    int(num(entry.get("bought"), 0)),
                    int(num(entry.get("sales"), 0)),
                    gold(entry.get("income")),
                    gold(entry.get("cost")),
                    gold(entry.get("cut")),
                    gold(entry.get("deposit")),
                    gold(entry.get("received")),
                    gold(entry.get("best")),
                    to_datetime(entry.get("bestAt")),
                    to_datetime(entry.get("last")),
                    gold(entry.get("unitMin")),
                    gold(entry.get("unitMax")),
                    quality_name(entry.get("quality")) if entry.get("quality") is not None else "",
                ]
            )
        for entry in as_list(ah.get("recent")):
            entry = as_dict(entry)
            activity_rows.append(
                [
                    profile["name"],
                    profile["realm"],
                    to_datetime(entry.get("at")),
                    text(entry.get("kind"), ""),
                    text(entry.get("name"), ""),
                    text(entry.get("id"), ""),
                    int(num(entry.get("units"), 0)),
                    gold(entry.get("price")),
                    gold(entry.get("buyout")),
                    quality_name(entry.get("quality")) if entry.get("quality") is not None else "",
                ]
            )
        for entry in as_list(ah.get("buys")):
            entry = as_dict(entry)
            activity_rows.append(
                [
                    profile["name"],
                    profile["realm"],
                    to_datetime(entry.get("at")),
                    "buy",
                    text(entry.get("name"), ""),
                    text(entry.get("id"), ""),
                    int(num(entry.get("units"), 0)),
                    gold(entry.get("price")),
                    None,
                    quality_name(entry.get("quality")) if entry.get("quality") is not None else "",
                ]
            )
        live = as_dict(ah.get("live"))
        for entry in as_list(live.get("rows")):
            entry = as_dict(entry)
            activity_rows.append(
                [
                    profile["name"],
                    profile["realm"],
                    to_datetime(live.get("at")),
                    "live",
                    text(entry.get("name"), ""),
                    text(entry.get("id"), ""),
                    int(num(entry.get("units"), 0)),
                    gold(entry.get("bid")),
                    gold(entry.get("buyout")),
                    quality_name(entry.get("quality")) if entry.get("quality") is not None else "",
                ]
            )

    if summary_rows:
        summary_rows.sort(key=lambda row: (-row[5], row[0].lower()))
        exporter.add_sheet(
            "Auction",
            summary_headers,
            summary_rows,
            "Auction house totals per character: what was posted, sold, bought and expired.",
            money=[
                "Sold for (g)",
                "Spent (g)",
                "Cut (g)",
                "Received (g)",
                "Best sale price (g)",
                "Best sale net (g)",
                "Best buy (g)",
            ],
            ints=["Posted", "Sold", "Units sold", "Bought units", "Expired", "Cancelled", "Items tracked"],
            widths={"Best sale": 24, "Best buy": 24},
            tab_color="BF8F00",
        )
    if item_rows:
        item_rows.sort(key=lambda row: (row[0].lower(), -row[7]))
        exporter.add_sheet(
            "Auction items",
            item_headers,
            item_rows,
            "Auction house figures grouped by item.",
            money=["Income (g)", "Cost (g)", "Cut (g)", "Deposit (g)", "Received (g)", "Best (g)", "Min unit (g)", "Max unit (g)"],
            dates=["Best date", "Last"],
            ints=["Units", "Bought", "Sales"],
            widths={"Item": 28},
            tab_color="BF8F00",
        )
    if activity_rows:
        activity_rows.sort(key=lambda row: (row[2] or datetime.min), reverse=True)
        exporter.add_sheet(
            "Auction activity",
            activity_headers,
            activity_rows,
            "Recent auction events, live auctions and purchases.",
            money=["Price (g)", "Buyout (g)"],
            dates=["Date"],
            ints=["Units"],
            widths={"Item": 26, "Type": 12},
            tab_color="BF8F00",
        )


def add_social(exporter: Exporter, profiles: List[Dict[str, Any]]) -> None:
    headers = [
        "Character",
        "Realm",
        "Guild",
        "Guild joins",
        "Guild leaves",
        "Guildless time",
        "Known players",
        "Chat sent",
        "Say",
        "Yell",
        "Whisper",
        "Party",
        "Guild chat",
        "Raid",
        "Emote",
        "Other",
        "Whispers sent",
        "Whispers received",
        "Mail sent",
        "Mail received",
        "Packages",
        "COD",
        "Trades",
        "Items given",
        "Items received",
        "Gold given (g)",
        "Gold received (g)",
        "Duels won",
        "Duels lost",
        "Duels accepted",
        "Duels challenged",
        "Solo time",
        "Party time",
        "Raid time",
        "Leader time",
    ]
    rows = []
    for profile in profiles:
        social = profile["social"]
        if not social:
            continue
        guild = as_dict(social.get("guild"))
        chat = as_dict(social.get("chat"))
        whispers = as_dict(social.get("whispers"))
        mail = as_dict(social.get("mail"))
        trades = as_dict(social.get("trades"))
        duels = as_dict(social.get("duels"))
        time_store = as_dict(social.get("time"))
        rows.append(
            [
                profile["name"],
                profile["realm"],
                text(social.get("guildName") or guild.get("name"), ""),
                len(as_list(guild.get("joins"))),
                len(as_list(guild.get("leaves"))),
                duration_text(guild.get("guildless")),
                len(profile["knownPlayers"]),
                int(num(chat.get("sent"), 0)),
                int(num(chat.get("say"), 0)),
                int(num(chat.get("yell"), 0)),
                int(num(chat.get("whisper"), 0)),
                int(num(chat.get("party"), 0)),
                int(num(chat.get("guild"), 0)),
                int(num(chat.get("raid"), 0)),
                int(num(chat.get("emote"), 0)),
                int(num(chat.get("other"), 0)),
                int(num(whispers.get("sent"), 0)),
                int(num(whispers.get("received"), 0)),
                int(num(mail.get("sent"), 0)),
                int(num(mail.get("received"), 0)),
                int(num(mail.get("packages"), 0)),
                int(num(mail.get("cod"), 0)),
                int(num(trades.get("count"), 0)),
                int(num(trades.get("itemsGiven"), 0)),
                int(num(trades.get("itemsReceived"), 0)),
                gold(trades.get("goldGiven")),
                gold(trades.get("goldReceived")),
                int(num(duels.get("won"), 0)),
                int(num(duels.get("lost"), 0)),
                int(num(duels.get("accepted"), 0)),
                int(num(duels.get("challenged"), 0)),
                duration_text(time_store.get("solo")),
                duration_text(time_store.get("party")),
                duration_text(time_store.get("raid")),
                duration_text(time_store.get("leader")),
            ]
        )
    if not rows:
        return
    rows.sort(key=lambda row: row[0].lower())
    exporter.add_sheet(
        "Social",
        headers,
        rows,
        "Chat, mail, trades, duels and group time for each character.",
        money=["Gold given (g)", "Gold received (g)"],
        ints=[
            "Guild joins",
            "Guild leaves",
            "Known players",
            "Chat sent",
            "Say",
            "Yell",
            "Whisper",
            "Party",
            "Guild chat",
            "Raid",
            "Emote",
            "Other",
            "Whispers sent",
            "Whispers received",
            "Mail sent",
            "Mail received",
            "Packages",
            "COD",
            "Trades",
            "Items given",
            "Items received",
            "Duels won",
            "Duels lost",
            "Duels accepted",
            "Duels challenged",
        ],
        widths={"Guild": 22},
        tab_color="C55A11",
    )

    known_headers = ["Character", "Realm", "Player", "Description"]
    known_rows = []
    for profile in profiles:
        for player, description in profile["knownPlayers"].items():
            known_rows.append(
                [profile["name"], profile["realm"], text(player), text(description)]
            )
    if known_rows:
        known_rows.sort(key=lambda row: (row[0].lower(), row[2].lower()))
        exporter.add_sheet(
            "Known players",
            known_headers,
            known_rows,
            "The players Tally has met, with the race and class it saw.",
            widths={"Player": 24, "Description": 24},
            tab_color="C55A11",
        )


def add_settings(exporter: Exporter, data: Dict[str, Any]) -> None:
    settings = as_dict(data.get("settings"))
    if not settings:
        return
    rows_flat: List[Tuple[str, Any]] = []
    flatten("settings", settings, rows_flat)
    rows = [[key, json_value(value)] for key, value in sorted(rows_flat, key=lambda item: item[0])]
    exporter.add_sheet(
        "Settings",
        ["Key", "Value"],
        rows,
        "The addon settings stored in the saved variable.",
        widths={"Key": 46, "Value": 60},
        wrap=["Value"],
        tab_color="7F7F7F",
    )


def add_charts(exporter: Exporter, profiles: List[Dict[str, Any]]) -> None:
    """A small chart sheet, kept separate so the data sheets stay tidy."""
    if not profiles:
        return

    sheet = exporter.workbook.create_sheet("Charts")
    sheet.sheet_view.showGridLines = False
    sheet.page_setup.orientation = "landscape"
    sheet.sheet_properties.tabColor = "2F5597"
    for column, width in (("A", 26), ("B", 16), ("C", 16), ("D", 16), ("E", 16), ("F", 16), ("G", 16), ("H", 16)):
        sheet.column_dimensions[column].width = width

    title = sheet.cell(row=1, column=1, value="Charts")
    title.font = TITLE_FONT
    title.fill = TITLE_FILL
    sheet.merge_cells("A1:H1")
    sheet.row_dimensions[1].height = 30
    sheet.cell(row=2, column=1, value="The same figures as the data sheets, drawn for a quick look.").font = SUBTITLE_FONT
    data_rows = 0

    def block_header(row: int, headers: Sequence[str]) -> None:
        for column, header in enumerate(headers, 1):
            cell = sheet.cell(row=row, column=column, value=header)
            cell.fill = HEADER_FILL
            cell.font = HEADER_FONT
            cell.alignment = HEADER_ALIGNMENT

    # Played by character.
    played = sorted(profiles, key=lambda profile: profile["played"], reverse=True)[:15]
    block_header(4, ["Character", "Played (hours)"])
    for index, profile in enumerate(played, 5):
        sheet.cell(row=index, column=1, value=profile["name"])
        sheet.cell(row=index, column=2, value=profile["played"] / 3600.0).number_format = DECIMAL_FORMAT
    data_rows += len(played)
    if played:
        chart = BarChart()
        chart.type = "bar"
        chart.style = 10
        chart.title = "Played by character"
        chart.y_axis.title = "Hours"
        chart.x_axis.title = None
        data = Reference(sheet, min_col=2, min_row=4, max_row=4 + len(played))
        cats = Reference(sheet, min_col=1, min_row=5, max_row=4 + len(played))
        chart.add_data(data, titles_from_data=True)
        chart.set_categories(cats)
        chart.height = 8.5
        chart.width = 15
        chart.legend = None
        sheet.add_chart(chart, "D4")

    # Loot by quality.
    quality_totals: Dict[int, int] = {}
    for profile in profiles:
        for quality, count in profile["lootQuality"].items():
            number = int(num(quality, 0))
            quality_totals[number] = quality_totals.get(number, 0) + int(num(count, 0))
    if any(value > 0 for value in quality_totals.values()):
        block_header(23, ["Quality", "Items"])
        row = 24
        for quality in sorted(quality_totals):
            if quality_totals[quality] <= 0:
                continue
            sheet.cell(row=row, column=1, value=quality_name(quality))
            sheet.cell(row=row, column=2, value=quality_totals[quality]).number_format = INT_FORMAT
            row += 1
            data_rows += 1
        chart = BarChart()
        chart.type = "col"
        chart.style = 10
        chart.title = "Loot by quality"
        chart.y_axis.title = "Items"
        data = Reference(sheet, min_col=2, min_row=23, max_row=row - 1)
        cats = Reference(sheet, min_col=1, min_row=24, max_row=row - 1)
        chart.add_data(data, titles_from_data=True)
        chart.set_categories(cats)
        chart.height = 8.5
        chart.width = 15
        chart.legend = None
        sheet.add_chart(chart, "D23")

    # Daily income and expense, summed over every character.
    totals: Dict[date, Tuple[float, float]] = {}
    for profile in profiles:
        daily = as_dict(as_dict(profile["char"].get("gold")).get("daily"))
        for key, entry in daily.items():
            try:
                day = datetime.strptime(text(key), "%Y-%m-%d").date()
            except ValueError:
                continue
            entry = as_dict(entry)
            income, expense = totals.get(day, (0.0, 0.0))
            totals[day] = (
                income + gold(entry.get("income")),
                expense + gold(entry.get("expense")),
            )
    if totals:
        block_header(42, ["Date", "Income (g)", "Expense (g)"])
        row = 43
        for day in sorted(totals):
            income, expense = totals[day]
            sheet.cell(row=row, column=1, value=datetime.combine(day, time.min)).number_format = DATE_FORMAT
            sheet.cell(row=row, column=2, value=income).number_format = MONEY_FORMAT
            sheet.cell(row=row, column=3, value=expense).number_format = MONEY_FORMAT
            row += 1
            data_rows += 1
        chart = LineChart()
        chart.style = 12
        chart.title = "Daily gold, all characters"
        chart.y_axis.title = "Gold"
        chart.x_axis.title = "Date"
        data = Reference(sheet, min_col=2, max_col=3, min_row=42, max_row=row - 1)
        cats = Reference(sheet, min_col=1, min_row=43, max_row=row - 1)
        chart.add_data(data, titles_from_data=True)
        chart.set_categories(cats)
        chart.height = 9
        chart.width = 22
        sheet.add_chart(chart, "D42")

    exporter.summaries.append(
        ("Charts", data_rows, "Bar and line charts for played time, loot quality and daily gold.")
    )


def write_overview(
    sheet: Any,
    profiles: List[Dict[str, Any]],
    data: Dict[str, Any],
    source: Path,
    output: Path,
    summaries: List[Tuple[str, int, str]],
) -> None:
    sheet.sheet_view.showGridLines = False
    sheet.page_setup.orientation = "landscape"
    sheet.sheet_properties.pageSetUpPr.fitToPage = True
    sheet.page_setup.fitToWidth = 1
    sheet.page_setup.fitToHeight = 0
    widths = {"A": 24, "B": 34, "C": 24, "D": 42}
    for column, width in widths.items():
        sheet.column_dimensions[column].width = width

    sheet.merge_cells("A1:D1")
    for column in range(1, 5):
        sheet.cell(row=1, column=column).fill = TITLE_FILL
    title = sheet["A1"]
    title.value = "Tally data export"
    title.font = TITLE_FONT
    title.alignment = Alignment(vertical="center", horizontal="left", indent=1)
    sheet.row_dimensions[1].height = 34

    sheet.merge_cells("A2:D2")
    source_cell = sheet["A2"]
    source_cell.value = f"SavedVariables: {source}"
    source_cell.font = SUBTITLE_FONT
    source_cell.alignment = Alignment(vertical="center")

    sheet.merge_cells("A3:D3")
    generated_cell = sheet["A3"]
    generated_cell.value = f"Generated {datetime.now():%Y-%m-%d %H:%M}  ·  workbook: {output.name}"
    generated_cell.font = SUBTITLE_FONT
    generated_cell.alignment = Alignment(vertical="center")

    def section_header(row_index: int, label: str) -> None:
        for column in range(1, 5):
            sheet.cell(row=row_index, column=column).fill = SECTION_FILL
        cell = sheet.cell(row=row_index, column=1, value=label)
        cell.font = SECTION_FONT
        sheet.merge_cells(start_row=row_index, start_column=1, end_row=row_index, end_column=4)

    row = 5
    section_header(row, "At a glance")
    row += 1

    total_played = sum(profile["played"] for profile in profiles)
    total_gold = sum(profile["goldBalance"] for profile in profiles)
    total_income = sum(profile["goldIncome"] for profile in profiles)
    total_expense = sum(profile["goldExpense"] for profile in profiles)
    total_sessions = sum(profile["sessionCount"] for profile in profiles)
    total_kills = sum(profile["kills"] for profile in profiles)
    total_deaths = sum(profile["deaths"] for profile in profiles)
    total_quests = sum(profile["quests"] for profile in profiles)
    total_items = sum(profile["lootItems"] for profile in profiles)
    total_zones = sum(len(profile["zones"]) for profile in profiles)
    total_fishing_casts = sum(profile["fishingCasts"] for profile in profiles)
    total_fishing_catches = sum(profile["fishingCatches"] for profile in profiles)
    total_records = sum(len(profile["records"]) for profile in profiles)
    realms = len({profile["realm"] for profile in profiles if profile["realm"]})

    metrics = [
        ("Characters", len(profiles), "realms: " + str(realms)),
        ("Total played", duration_text(total_played), f"{total_played:,} seconds"),
        ("Gold balance", f"{total_gold:,.4f} g", "current purse, all characters"),
        ("Gold earned", f"{total_income:,.4f} g", "recorded income"),
        ("Gold spent", f"{total_expense:,.4f} g", "recorded expenses"),
        ("Sessions", total_sessions, f"{duration_text(sum(profile['sessionSeconds'] for profile in profiles))} tracked"),
        ("Kills", total_kills, f"{total_deaths:,} deaths"),
        ("Quests", total_quests, "turn-ins recorded"),
        ("Items looted", total_items, f"{sum(profile['lootValue'] for profile in profiles):,.4f} g vendor value"),
        ("Zones visited", total_zones, f"{sum(len(profile['dungeons']) for profile in profiles):,} dungeons"),
        ("Fishing", f"{total_fishing_casts:,} casts", f"{total_fishing_catches:,} catches"),
        ("Records", total_records, "personal bests stored"),
    ]
    for label, value, detail in metrics:
        sheet.cell(row=row, column=1, value=label).font = Font(bold=True)
        sheet.cell(row=row, column=2, value=value)
        sheet.cell(row=row, column=3, value=detail).font = NOTE_FONT
        row += 1

    row += 1
    section_header(row, "Highlights")
    row += 1
    for column, header in enumerate(["Highlight", "Character", "Realm", "Value"], 1):
        cell = sheet.cell(row=row, column=column, value=header)
        cell.fill = HEADER_FILL
        cell.font = HEADER_FONT
        cell.alignment = HEADER_ALIGNMENT
    row += 1

    def best_profile(
        field: str, numeric: bool = False, key: Optional[Any] = None
    ) -> Optional[Dict[str, Any]]:
        if not profiles:
            return None
        if key is not None:
            return max(profiles, key=key)
        if numeric:
            return max(profiles, key=lambda profile: num(profile.get(field), 0))
        return max(profiles, key=lambda profile: profile.get(field) or 0)

    highlights = [
        ("Most played", best_profile("played", True), lambda p: duration_text(p["played"])),
        ("Highest level", best_profile("level", True), lambda p: str(p["level"])),
        ("Richest", best_profile("goldBalance"), lambda p: f"{p['goldBalance']:,.4f} g"),
        ("Most kills", best_profile("kills", True), lambda p: f"{p['kills']:,}"),
        ("Most quests", best_profile("quests", True), lambda p: f"{p['quests']:,}"),
        ("Most items looted", best_profile("lootItems", True), lambda p: f"{p['lootItems']:,}"),
        (
            "Most zones",
            best_profile("zones", key=lambda p: len(p["zones"])),
            lambda p: str(len(p["zones"])),
        ),
        ("Most fish caught", best_profile("fishingCatches", True), lambda p: f"{p['fishingCatches']:,}"),
        ("Longest session", best_profile("longestSession", True), lambda p: duration_text(p["longestSession"])),
    ]
    for label, profile, formatter in highlights:
        if not profile:
            continue
        sheet.cell(row=row, column=1, value=label).font = Font(bold=True)
        sheet.cell(row=row, column=2, value=profile["name"])
        sheet.cell(row=row, column=3, value=profile["realm"])
        sheet.cell(row=row, column=4, value=formatter(profile))
        row += 1

    row += 1
    section_header(row, "Sheets")
    row += 1
    for column, header in enumerate(["Sheet", "Rows", "Description", ""], 1):
        cell = sheet.cell(row=row, column=column, value=header)
        if header:
            cell.fill = HEADER_FILL
            cell.font = HEADER_FONT
            cell.alignment = HEADER_ALIGNMENT
    row += 1
    for sheet_name, count, description in summaries:
        sheet.cell(row=row, column=1, value=sheet_name)
        sheet.cell(row=row, column=2, value=count).number_format = INT_FORMAT
        sheet.cell(row=row, column=3, value=description).alignment = Alignment(
            vertical="top", wrap_text=True
        )
        sheet.merge_cells(start_row=row, start_column=3, end_row=row, end_column=4)
        sheet.row_dimensions[row].height = 28
        row += 1

    row += 1
    section_header(row, "Notes")
    row += 1
    notes = [
        "Money is gold: 1 g = 10,000 copper. The (g) columns are numeric and can be summed or charted.",
        "Durations are shown as days/hours/minutes/seconds, and the (seconds) columns are exact.",
        "A blank cell means Tally has no value for that field, not that the value is zero.",
        "Tally caps some lists itself: 60 finished sessions, 80 recent gold changes and 50 best finds per character. The daily ledger keeps up to a year.",
        "Fishing catches are items looted during a Fishing cast, including junk and pool items.",
        "The workbook was made from the saved variable only; it did not read the game or change any addon data.",
    ]
    for note in notes:
        sheet.cell(row=row, column=1, value="•").font = NOTE_FONT
        cell = sheet.cell(row=row, column=2, value=note)
        cell.font = NOTE_FONT
        cell.alignment = Alignment(vertical="top", wrap_text=True)
        sheet.merge_cells(start_row=row, start_column=2, end_row=row, end_column=4)
        sheet.row_dimensions[row].height = 28
        row += 1


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def default_output_path(script_dir: Path) -> Path:
    stamp = datetime.now().strftime("%Y-%m-%d-%H%M%S")
    return script_dir / f"Tally-Export-{stamp}.xlsx"


def open_file(path: Path) -> None:
    try:
        if os.name == "nt":
            os.startfile(str(path))  # type: ignore[attr-defined]
        elif sys.platform == "darwin":
            subprocess.Popen(["open", str(path)])
        else:
            subprocess.Popen(["xdg-open", str(path)])
    except Exception as exc:
        print(f"Could not open the workbook: {exc}", file=sys.stderr)


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Export the Tally addon's SavedVariables to a formatted .xlsx workbook.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Examples:\n"
            "  python export_tally.py\n"
            '  python export_tally.py "G:/Games/World of Warcraft/_classic_era_"\n'
            '  python export_tally.py --savedvars "G:/Games/World of Warcraft/_classic_era_/WTF/Account/NAME/SavedVariables/Tally.lua"\n'
            '  python export_tally.py --out "D:/reports/Tally.xlsx" --open\n'
        ),
    )
    parser.add_argument(
        "path",
        nargs="?",
        help="Tally.lua, a SavedVariables folder, an addon folder, or a game folder.",
    )
    parser.add_argument(
        "--savedvars",
        help="Explicit path to Tally.lua (or a folder that contains it).",
    )
    parser.add_argument(
        "--addon",
        help="Path to the Tally addon folder; the game's WTF folder is derived from it.",
    )
    parser.add_argument(
        "--out",
        help="Output .xlsx file or folder. Defaults to the folder this script lives in.",
    )
    parser.add_argument(
        "--account",
        help="Only use the SavedVariables of this account name when several are found.",
    )
    parser.add_argument(
        "--no-tables",
        action="store_true",
        help="Use plain ranges and autofilters instead of Excel tables.",
    )
    parser.add_argument(
        "--open",
        action="store_true",
        help="Open the workbook after it is written.",
    )
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_argument_parser().parse_args(argv)

    if Workbook is None:
        print(
            "This exporter needs openpyxl.\n"
            "Install it with:  python -m pip install openpyxl",
            file=sys.stderr,
        )
        return 2

    script_dir = Path(__file__).resolve().parent
    explicit = args.savedvars or args.path
    try:
        source, candidates = find_saved_variables(
            script_dir, explicit, args.addon, args.account
        )
    except FileNotFoundError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    if len(candidates) > 1:
        print("Found several SavedVariables files; using the newest:")
        for candidate in candidates[:6]:
            print(f"  {candidate}")
        if len(candidates) > 6:
            print(f"  ... and {len(candidates) - 6} more")
        print()

    print(f"Reading {source}")
    try:
        data = read_saved_variables(source)
    except (OSError, LuaParseError) as exc:
        print(f"Could not read the saved variable: {exc}", file=sys.stderr)
        return 1

    chars = as_dict(data.get("chars"))
    if not chars:
        print("No characters found in the saved variable.", file=sys.stderr)
        return 1

    profiles = [build_profile(key, char) for key, char in chars.items() if isinstance(char, dict)]
    if not profiles:
        print("The saved variable has characters, but none are usable tables.", file=sys.stderr)
        return 1
    profiles.sort(key=lambda profile: (profile["realm"].lower(), profile["name"].lower()))
    print(f"Found {len(profiles)} character(s).")

    workbook = Workbook()
    workbook.remove(workbook.active)
    workbook.properties.title = "Tally data export"
    workbook.properties.subject = "World of Warcraft statistics from the Tally addon"
    workbook.properties.creator = "Tally export_tally.py"
    workbook.properties.description = f"Exported from {source}"
    workbook.properties.created = datetime.now()

    exporter = Exporter(workbook, use_tables=not args.no_tables)

    # Overview is created first so it is the first tab, and filled last when
    # the list of sheets is complete. Charts follow it so the visual summary
    # is one click away from the front page.
    overview = workbook.create_sheet("Overview")
    add_charts(exporter, profiles)

    add_characters(exporter, profiles)
    add_sessions(exporter, profiles)
    add_gold_transactions(exporter, profiles)
    add_daily_gold(exporter, profiles)
    add_professions(exporter, profiles)
    add_profession_gains(exporter, profiles)
    add_fishing(exporter, profiles)
    add_gathering(exporter, profiles)
    add_merchants_favor(exporter, profiles)
    add_loot(exporter, profiles)
    add_combat(exporter, profiles)
    add_explore(exporter, profiles)
    add_milestones(exporter, profiles)
    add_records(exporter, profiles)
    add_auction(exporter, profiles)
    add_social(exporter, profiles)
    add_settings(exporter, data)

    if args.out:
        output_arg = Path(args.out).expanduser()
        if output_arg.is_dir() or not output_arg.suffix:
            output = output_arg / default_output_path(script_dir).name
        else:
            output = output_arg
            if output.suffix.lower() != ".xlsx":
                output = output.with_suffix(".xlsx")
    else:
        output = default_output_path(script_dir)

    try:
        output.parent.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        print(f"Could not create the output folder {output.parent}: {exc}", file=sys.stderr)
        return 1
    write_overview(overview, profiles, data, source, output, exporter.summaries)
    overview.sheet_properties.tabColor = "BF8F00"

    try:
        workbook.save(output)
    except OSError as exc:
        print(f"Could not write {output}: {exc}", file=sys.stderr)
        return 1

    print(f"Wrote {len(exporter.summaries) + 1} sheets to {output}")
    if args.open:
        open_file(output)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\nCancelled.", file=sys.stderr)
        raise SystemExit(130)
