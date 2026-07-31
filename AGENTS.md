# AGENTS.md

Guidance for AI coding agents working in `highlightsync.koplugin`. Read this before touching any file.

## Global rule: search KOReader core first

Before writing ANY code including a new Lua utility, UI pattern, or API call, **always search
the sibling `koreader/` folder** for existing implementations.
KOReader ships a large frontend library (`frontend/`, `plugins/`) — reuse its helpers, widgets,
and conventions rather than reinventing them.

## What this plugin is

A KOReader plugin that **synchronizes and merges highlights, notes, and bookmarks** across
multiple devices or cloud backup locations. It stores annotations as JSON on WebDAV or Dropbox
and performs a three-way merge (local / server / last-sync snapshot) so that offline edits on
multiple devices converge without data loss.

## File map

- `main.lua` — plugin entry point: menu registration, sync orchestration, upload/download,
  debounce timer, JSON read/write helpers, `ext` key stringification for PDF annotations.
- `merge.lua` — stateless three-way merge logic: `merge_highlights`, `merge_bookmarks`.
  Keying strategy: `pos0|pos1` XPath positions (stable across devices); falls back to
  `page|text-hash` for older annotations. Timestamps decide which version wins when a key
  exists on both sides.
- `insert_menu.lua` — injects the "highlight_sync" entry into both the File Manager and
  Reader tool menus, after the "statistics" item.
- `highlightsync_gettext.lua` — pure-Lua gettext subset (adapted from `assistant.koplugin`).
  Loads `.po` files from `l10n/` at runtime.
- `l10n/zh_CN/`, `l10n/zh_TW/` — Simplified and Traditional Chinese translation catalogs.
- `_meta.lua` — plugin metadata (name / version / description).

## i18n rule

All user-visible strings **must** go through `highlightsync_gettext.lua` (aliased as `_`).

- Load it at the top of each Lua file that shows UI: `local _ = require("highlightsync_gettext")`.
- Wrap every user-visible string: `_("Your string here")`.
- When you add a new string, add it to **both** `l10n/zh_CN/*.po` and `l10n/zh_TW/*.po`.
- Never hardcode a translated string directly in `main.lua` or other Lua files.
- **Never concatenate a non-ASCII string literal with `_()`.**  Patterns like
  `"✓ " .. _("key")` produce partially-translated strings that `check_i18n.py` will flag.
  Put the whole visible string into a dedicated translation key instead.

## Merge contract

`merge.lua` is a **pure function module** — it must never require UI or side-effectful modules.

- `merge_highlights(local_annotations, server_annotations, last_sync_annotations)` → `merged_table, changed_bool`
- `merge_bookmarks(local_bookmarks, server_bookmarks, last_sync_bookmarks)` → `merged_table, changed_bool`
- Keys are built from `pos0|pos1`; never change the keying strategy without also updating the
  fallback path and any existing cached JSON data.
- Timestamp comparison uses `datetime_updated` falling back to `datetime` (ISO-like string
  `"YYYY-MM-DD HH:MM:SS"`). Equal timestamps keep the server version to avoid spurious
  change-detection diffs.

## Sync flow summary

1. Download server JSON → parse.
2. Load local annotations from KOReader's per-book `.sdr` directory.
3. Load last-sync snapshot (stored alongside the local annotations).
4. Call `merge.lua` helpers; write merged result back if changed.
5. Upload merged JSON to server.
6. Persist the merged result as the new last-sync snapshot.

Syncs are **debounced** (`SYNC_DEBOUNCE_DELAY = 25 s`) to avoid hammering the server on rapid
annotation events.

## Build / test / lint

- **No build step** — Lua files run directly in KOReader.
- **Lint**: `luacheck -q .` from inside `highlightsync.koplugin/` (see repo task
  "HighlightSync: lint").
- **i18n check**: `python check_i18n.py` from inside `highlightsync.koplugin/`.
  Scans every `_()` call in all `.lua` files and verifies each string has a `msgid` entry in
  **both** `l10n/zh_CN/koreader.po` and `l10n/zh_TW/koreader.po`. Exit 0 = clean.
  **Run this after every change that touches a `.lua` file or a `.po` file.**
- **Manual test**: install the plugin on a KOReader device or emulator, create annotations on
  two devices, sync both, and confirm the merged result contains all annotations from both sides
  without duplicates.

## Change checklist for agents

When editing merge logic in `merge.lua`:

1. Confirm the key-generation strategy is unchanged (or update all call sites if it must change).
2. Verify timestamp comparison still uses `datetime_updated` → `datetime` fallback order.
3. The `changed` boolean must be `false` when local and server are already identical — do not
   trigger an upload on a no-op sync.

When editing sync orchestration in `main.lua`:

4. Keep the upload/download order: download → merge → upload. Never upload before merging.
5. Preserve the debounce guard (`is_reloading_due_to_sync`) to prevent re-entrant sync loops.

When adding UI strings:

6. Wrap with `_()` and add to both `l10n/zh_CN/koreader.po` and `l10n/zh_TW/koreader.po`.
7. **Run `python check_i18n.py` and fix all errors before committing.**
   Exit 0 = clean. Any missing or orphaned msgid is a hard blocker.
