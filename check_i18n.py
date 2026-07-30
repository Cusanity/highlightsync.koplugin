"""
check_i18n.py — verify i18n coverage for highlightsync.koplugin.

Scans all .lua files for _("...") calls and compares against msgid entries in
every l10n/<lang>/koreader.po file.

Exit 0 = clean.  Non-zero = errors that must be fixed before committing.
"""

import re
import sys
from pathlib import Path

HERE = Path(__file__).parent

# ---------------------------------------------------------------------------
# Extract source strings from Lua files
# ---------------------------------------------------------------------------

# Matches _("...") and _('...'), single-line only.
# Multi-line strings are not supported by this plugin's gettext usage.
_LUA_GETTEXT_RE = re.compile(r'\b_\(\s*(?:"((?:[^"\\]|\\.)*)"|\'((?:[^\'\\]|\\.)*)\')\s*\)')


def collect_lua_strings() -> dict[str, list[str]]:
    """Return {msgid: [file:line, ...]} for every _() call in .lua files."""
    found: dict[str, list[str]] = {}
    for lua_file in sorted(HERE.glob("*.lua")):
        for lineno, line in enumerate(lua_file.read_text(encoding="utf-8").splitlines(), 1):
            for m in _LUA_GETTEXT_RE.finditer(line):
                msgid = m.group(1) if m.group(1) is not None else m.group(2)
                # Unescape basic Lua escape sequences
                msgid = msgid.replace('\\"', '"').replace("\\'", "'").replace("\\\\", "\\")
                key = f"{lua_file.name}:{lineno}"
                found.setdefault(msgid, []).append(key)
    return found


# ---------------------------------------------------------------------------
# Parse .po files
# ---------------------------------------------------------------------------

_MSGID_RE = re.compile(r'^msgid\s+"((?:[^"\\]|\\.)*)"')
_MSGID_CONT_RE = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"')


def parse_po_msgids(po_path: Path) -> set[str]:
    """Return the set of non-empty msgids defined in a .po file."""
    msgids: set[str] = set()
    lines = po_path.read_text(encoding="utf-8").splitlines()
    i = 0
    while i < len(lines):
        m = _MSGID_RE.match(lines[i])
        if m:
            value = m.group(1)
            # Concatenate continuation lines
            j = i + 1
            while j < len(lines):
                cm = _MSGID_CONT_RE.match(lines[j])
                if cm:
                    value += cm.group(1)
                    j += 1
                else:
                    break
            if value:  # skip the header entry (empty msgid)
                msgids.add(value.replace('\\"', '"').replace("\\'", "'"))
            i = j
        else:
            i += 1
    return msgids


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    lua_strings = collect_lua_strings()
    source_ids = set(lua_strings.keys())

    po_files = sorted((HERE / "l10n").rglob("koreader.po"))
    if not po_files:
        print("ERROR: no l10n/*/koreader.po files found", file=sys.stderr)
        return 1

    errors = 0

    for po_path in po_files:
        lang = po_path.parent.name
        po_ids = parse_po_msgids(po_path)

        missing = source_ids - po_ids
        orphaned = po_ids - source_ids

        if missing:
            errors += len(missing)
            print(f"\n[{lang}] MISSING translations ({len(missing)}):")
            for msgid in sorted(missing):
                locs = ", ".join(lua_strings[msgid])
                print(f"  {locs!s:40s}  {msgid!r}")

        if orphaned:
            print(f"\n[{lang}] ORPHANED entries — msgid in .po but no longer in Lua ({len(orphaned)}):")
            for msgid in sorted(orphaned):
                print(f"  {msgid!r}")

        if not missing and not orphaned:
            print(f"[{lang}] OK — {len(po_ids)} strings, all covered.")

    if errors:
        print(f"\n{errors} error(s). Fix them before committing.", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
