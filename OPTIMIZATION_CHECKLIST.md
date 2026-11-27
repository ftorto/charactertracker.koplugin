# Memory & performance optimisation checklist

## Completed items (checked after last rebuild)

- [x] **Debounced saves** + atomic write via `path..".tmp"` + `os.rename`. Falls back to direct io.open/write if rename fails on FAT. `_dirty` flag + `scheduleSave()` with 3s debounce.
- [x] **Lazy indexes** via `markDirty()` / `invalidateIndexes()` / `ensureIndexes()`. Indexes only rebuilt when a relevant kind changed (`"names"`, `"rels"`, or `"all"`). No more `rebuildCaches()` on every `saveData()`.
- [x] **`normalizeName` memoisation**: `cachedNameKey()` uses a weak-keyed table so the key is computed once per character and never written to JSON. Hoisted out of inner loops.
- [x] **`sortCharacters()`**: sorts on cached keys via `cachedNameKey()` instead of calling `normalizeName()` in the comparator.
- [x] **Stable `id` per character**: generated with `newId()`, migrated from old JSON on load via migration script. Relationships now store `target_id` instead of `target` string, eliminating O(n) scans for renames/deletes.
- [x] **`showMenu` helper** replaces one-`ButtonDialog`-per-row patterns. Notes / aliases / relationships / series pickers now use a scrollable `Menu` instead of hundreds of buttons, dramatically reducing RAM churn.
- [x] **Detail view refreshed in place**: `TextViewer` with `reinit()` instead of rebuilding from scratch each time. The viewer's text string is updated and `reinit()` redraws.
- [x] **Dialog references cleared**: all `_alias_dialog`, `_rel_dialog`, `_rel_picker`, `_rel_type_picker`, `_rating_dialog`, `_role_dialog`, `_series_dialog` set to `nil` via `tap_close_callback`.
- [x] **`unlinkFromSeries`** no longer wipes the per‑book `characters.json`. It flushes pending edits (`saveData(true)`), sets series name to `nil`, and `loadData()` to restore the original list.
- [x] **`seriesFileName()`** is now idempotent (percent‑encodes everything except spaces → `_`), so two different series names never map to the same file. `seriesNameFromFile()` reverses it.
- [x] **Dead code removed**: `getCurrentPage`, `getCurrentChapter` and their only caller `getTocTitleByPage` were deleted.
- [x] **Duplicate validation block removed**: `showAddAliasDialog` had two identical `normalizeName(alias) == normalizeName(character.name)` checks; kept only one.
- [x] **README updated**: removed the “underline names / findAllText” section (never implemented); added reference to the new id‑based model.
- [x] **Version bump / audit complete**: all mutation functions now call `markDirty()` instead of `saveData()` where appropriate, and `ensureIndexes()` guards every index‑dependent lookup.

## Trade‑offs / known remaining items

- Relationships that were stored as `target` string have been migrated to `target_id`. Old JSON files without an `id` field get the migration on next `loadData()`.
- If the device is killed mid‑write (before `os.rename`), the old `path` may contain a truncated JSON file. The fallback `pcall(json.decode)` at load time means the user sees “corrupted file” and loses that series' data — but the main book data is safe because the atomic write happens on the *new* path.
- The `findAllText` feature was never implemented; the README now just says it's not available rather than promising it.

## File changes summary

| File | Main changes |
|------|-------------|
| `main.lua` | `init()`, `markDirty()`, `scheduleSave()`, `loadData()`, `saveData()`, `rebuildNameIndex()`, `rebuildRelationshipIndex()`, `ensureIndexes()`, weak‑keyed caches, stable ids, new index invalidation, debounced atomic writes, `showMenu` helper usage, micro‑opt star strings, migration, new helpers `seriesFileName()` / `seriesNameFromFile()`, dead‑code removal |
| `README.md` | Removed underline/findAllText section; added id‑based model reference; series‑file‑name encoding docs |

All files pass Lua syntax check (`luaparser` AST parse succeeds).