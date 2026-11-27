--[[
    Character Tracker Plugin for KOReader
    Track characters and add notes while reading.

    Structure:
    - Characters are stored per-book in a JSON file in the book's sidecar directory.
    - Books can be linked to a "series" to share characters across multiple books.
    - Each character has: name, aliases, notes, relationships, rating, role.
    - Integrates with KOReader's highlight dialog via addToHighlightDialog().
    - Adds a menu entry under Tools for managing characters.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Screen = require("device").screen
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local Device = require("device")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local json = require("json")
local _ = require("gettext")
local T = require("ffi/util").template

local CharacterTracker = WidgetContainer:extend{
    name = "charactertracker",
    is_doc_only = true,
    characters = nil,
    data_file = nil,
    character_lookup = nil,
    character_by_id = nil,
    incoming_relationship_lookup = nil,
    character_list_cache = nil,
    characters_sorted = false,
    -- Lazily maintained state (see ensureIndexes / markDirty)
    _name_index_dirty = false,
    _rel_index_dirty = false,
    _list_dirty = true,
    _dirty = false,
    _save_scheduled = false,
    _scheduled_save = nil,
    _positions = nil,
    _series_dir = nil,
    _series_cache = nil,
}

-- Relationship type definitions
local RELATIONSHIP_TYPES = {
    -- Family
    { key = "father",   label = _("Father"),   category = "family" },
    { key = "mother",   label = _("Mother"),   category = "family" },
    { key = "son",      label = _("Son"),      category = "family" },
    { key = "daughter", label = _("Daughter"), category = "family" },
    { key = "brother",  label = _("Brother"),  category = "family" },
    { key = "sister",   label = _("Sister"),   category = "family" },
    { key = "spouse",   label = _("Spouse"),   category = "family" },
    { key = "family",   label = _("Family"),   category = "family" },
    -- Location
    { key = "located",     label = _("Located"),     category = "location" },

    -- Social
    { key = "ally",     label = _("Ally"),     category = "social" },
    { key = "enemy",    label = _("Enemy"),    category = "social" },
    { key = "friend",   label = _("Friend"),   category = "social" },
    { key = "mentor",   label = _("Mentor"),   category = "social" },
    { key = "servant",  label = _("Servant"),  category = "social" },
    { key = "master",   label = _("Master"),   category = "social" },
    { key = "lover",    label = _("Lover"),    category = "social" },
    -- Custom
    { key = "custom",   label = _("Custom…"),  category = "other" },
}

local RELATIONSHIP_LABELS = {}
for _i, relationship in ipairs(RELATIONSHIP_TYPES) do
    RELATIONSHIP_LABELS[relationship.key] = relationship.label
end

local function getRelationshipLabel(type_key)
    if type_key and RELATIONSHIP_LABELS[type_key] then
        return RELATIONSHIP_LABELS[type_key]
    end
    return type_key or _("Unknown")
end

-- Role definitions
local ROLES = {
    { key = "",           label = _("Not set") },
    { key = "main",       label = _("Main") },
    { key = "secondary",  label = _("Secondary") },
    { key = "tertiary",   label = _("Tertiary") },
    { key = "mentioned",  label = _("Mentioned") },
    { key = "antagonist", label = _("Antagonist") },
    { key = "narrator",   label = _("Narrator") },
}

local ROLE_LABELS = {}
for _i, role in ipairs(ROLES) do
    ROLE_LABELS[role.key] = role.label
end

local function getRoleLabel(role_key)
    return ROLE_LABELS[role_key or ""] or _("Not set")
end

--- Trim leading/trailing whitespace.
local function trim(s)
    if not s then return "" end
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local function normalizeName(name)
    if type(name) ~= "string" then return "" end
    return trim(name):lower()
end

--- Get plain text from a note (supports legacy table format and current string format).
local function getNoteText(note)
    if type(note) == "table" then return note.text or "" end
    return tostring(note)
end

-- Delay (seconds) before an edit is written to disk.
local SAVE_DELAY = 3

local id_sequence = 0

-- Precomputed star ratings: avoids two string.rep() and a concat per render.
local STAR_STRINGS = {}
do
    local no_rating = _("No rating")
    for i = 0, 5 do
        if i == 0 then
            STAR_STRINGS[0] = no_rating
        else
            STAR_STRINGS[i] = ("★"):rep(i) .. ("☆"):rep(5 - i)
        end
    end
end

local function starsString(rating)
    return STAR_STRINGS[tonumber(rating) or 0] or STAR_STRINGS[0]
end

-- Normalised names are recomputed a lot (sorting, lookups, index rebuilds).
-- Memoise them per character in a weak-keyed table: the cache follows the
-- character's lifetime and never leaks into the JSON file.
local normalized_name_cache = setmetatable({}, { __mode = "k" })

local function cachedNameKey(character)
    local key = normalized_name_cache[character]
    if key == nil then
        key = normalizeName(character.name)
        normalized_name_cache[character] = key
    end
    return key
end

-- ============================================================
-- INIT / LIFECYCLE
-- ============================================================

function CharacterTracker:init()
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
    self.characters = {}
    self.character_lookup = {}
    self.character_by_id = {}
    self.incoming_relationship_lookup = {}
    self.character_list_cache = nil
    self.characters_sorted = false
    self._name_index_dirty = false
    self._rel_index_dirty = false
    self._list_dirty = true
    self._dirty = false
    self._save_scheduled = false
    self._scheduled_save = nil
    self._positions = nil
    self._series_dir = nil
    self._series_cache = nil
end

function CharacterTracker:onDispatcherRegisterActions()
    Dispatcher:registerAction("character_tracker_show", {
        category = "none",
        event = "ShowCharacterList",
        title = _("Character Tracker: show characters"),
        reader = true,
    })
end

function CharacterTracker:onReaderReady()
    self:loadData()
    -- Register our button in the highlight dialog
    if self.ui.highlight then
        self.ui.highlight:addToHighlightDialog("charactertracker_assign", function(this)
            return {
                text = _("Character"),
                callback = function()
                    -- Capture selected text BEFORE closing (onClose clears it)
                    local selected = this.selected_text
                    this:onClose()
                    self:onAssignHighlightToCharacter(selected)
                end,
            }
        end)
    end
end

function CharacterTracker:onCloseDocument()
    self:saveData()
end

-- Flush any pending edit when the device sleeps or KOReader quits, so the
-- debounced save can never lose data.
function CharacterTracker:onSuspend()
    self:saveData()
end

function CharacterTracker:onFlushSettings()
    self:saveData()
end

function CharacterTracker:onCloseWidget()
    self:saveData()
end

-- ============================================================
-- DATA PERSISTENCE
-- ============================================================

--- Reversible encoding of a series name into a file name.
--- Only [A-Za-z0-9-] are kept, spaces become "_", everything else (including
--- "_" and "%") is percent-encoded. Unlike the previous sanitizer this cannot
--- map two different series names to the same file.
local function seriesFileName(series)
    local encoded = series:gsub("[^%w%-]", function(c)
        if c == " " then return "_" end
        return string.format("%%%02X", string.byte(c))
    end)
    return encoded .. ".json"
end

local function seriesNameFromFile(entry)
    local base = entry:gsub("%.json$", "")
    -- Underscores in the encoded name are always spaces (a literal "_" is
    -- stored as %5F), so this replacement is unambiguous.
    base = (base:gsub("_", " "))
    base = base:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end)
    return base
end

function CharacterTracker:getSeriesDir()
    if self._series_dir then return self._series_dir end
    local dir = DataStorage:getDataDir() .. "/character_tracker"
    lfs.mkdir(dir)
    self._series_dir = dir
    return dir
end

function CharacterTracker:getSeriesName()
    if not self.ui.doc_settings then return nil end
    return self.ui.doc_settings:readSetting("character_tracker_series")
end

function CharacterTracker:setSeriesName(name)
    if not self.ui.doc_settings then return end
    self.ui.doc_settings:saveSetting("character_tracker_series", name)
    -- Invalidate cached path so it recalculates
    self.data_file = nil
    self._series_cache = nil
end

function CharacterTracker:getDataFilePath()
    if self.data_file then return self.data_file end
    local series = self:getSeriesName()
    if series and series ~= "" then
        local dir = self:getSeriesDir()
        local path = dir .. "/" .. seriesFileName(series)
        -- Fall back to a file created by the old (lossy) sanitizer, so
        -- existing series keep working after the encoding change.
        if lfs.attributes(path, "mode") ~= "file" then
            local legacy_name = series:gsub("[^%w%s%-_]", ""):gsub("%s+", "_")
            local legacy_path = dir .. "/" .. legacy_name .. ".json"
            if lfs.attributes(legacy_path, "mode") == "file" then
                path = legacy_path
            end
        end
        self.data_file = path
    else
        if not self.ui.document then return nil end
        local doc_path = self.ui.document.file
        local sidecar_dir = DocSettings:getSidecarDir(doc_path)
        self.data_file = sidecar_dir .. "/" .. "characters.json"
    end
    return self.data_file
end

function CharacterTracker:sortCharacters()
    if self.characters_sorted then return end
    table.sort(self.characters, function(a, b)
        local a_name = cachedNameKey(a)
        local b_name = cachedNameKey(b)
        if a_name == b_name then
            return a.name < b.name
        end
        return a_name < b_name
    end)
    self.characters_sorted = true
    self._positions = nil
end

-- ============================================================
-- INDEXES
-- ============================================================

--- Mark one or more derived caches as stale. Rebuilding is deferred to the
--- next read (ensureIndexes), so a batch of edits costs one rebuild at most.
function CharacterTracker:invalidateIndexes(kind)
    if kind == "names" then
        self._name_index_dirty = true
    elseif kind == "rels" then
        self._rel_index_dirty = true
    else
        self._name_index_dirty = true
        self._rel_index_dirty = true
    end
    self._list_dirty = true
end

function CharacterTracker:ensureIndexes()
    if self._name_index_dirty then self:rebuildNameIndex() end
    if self._rel_index_dirty then self:rebuildRelationshipIndex() end
end

function CharacterTracker:rebuildNameIndex()
    self.character_lookup = {}
    self.character_by_id = {}
    for _i, char in ipairs(self.characters) do
        if char.id then
            self.character_by_id[char.id] = char
        end
        local own_key = cachedNameKey(char)
        if own_key ~= "" then
            self.character_lookup[own_key] = char
        end
        local aliases = char.aliases
        if aliases then
            for _j = 1, #aliases do
                local alias_key = normalizeName(aliases[_j])
                if alias_key ~= "" then
                    self.character_lookup[alias_key] = char
                end
            end
        end
    end
    self._name_index_dirty = false
end

--- Resolve the character a relationship points to (id first, legacy name next).
function CharacterTracker:resolveRelationshipTarget(rel)
    if rel.target_id and self.character_by_id then
        local target = self.character_by_id[rel.target_id]
        if target then return target end
    end
    if rel.target and self.character_lookup then
        return self.character_lookup[normalizeName(rel.target)]
    end
    return nil
end

function CharacterTracker:getRelationshipTargetName(rel)
    self:ensureIndexes()
    local target = self:resolveRelationshipTarget(rel)
    if target then return target.name end
    return rel.target or _("Unknown")
end

function CharacterTracker:getRelationshipSourceName(entry)
    self:ensureIndexes()
    if entry.source_id and self.character_by_id then
        local source = self.character_by_id[entry.source_id]
        if source then return source.name end
    end
    return entry.source or _("Unknown")
end

function CharacterTracker:rebuildRelationshipIndex()
    self.incoming_relationship_lookup = {}
    for _i, char in ipairs(self.characters) do
        local rels = char.relationships
        if rels then
            local source_id = char.id
            local source_name = char.name
            for _j = 1, #rels do
                local rel = rels[_j]
                local target = self:resolveRelationshipTarget(rel)
                if target and target ~= char then
                    local target_id = target.id
                    local incoming = self.incoming_relationship_lookup[target_id]
                    if not incoming then
                        incoming = {}
                        self.incoming_relationship_lookup[target_id] = incoming
                    end
                    incoming[#incoming + 1] = {
                        source_id = source_id,
                        source = source_name,
                        relationship_index = _j,
                        type = rel.type,
                    }
                end
            end
        end
    end
    self._rel_index_dirty = false
end

--- Flag an edit: invalidate the right indexes and schedule a debounced write.
function CharacterTracker:markDirty(kind)
    self:invalidateIndexes(kind)
    self._dirty = true
    self:scheduleSave()
end

function CharacterTracker:cancelScheduledSave()
    if self._save_scheduled and self._scheduled_save then
        UIManager:unschedule(self._scheduled_save)
    end
    self._save_scheduled = false
    self._scheduled_save = nil
end

function CharacterTracker:scheduleSave()
    if self._save_scheduled then return end
    self._save_scheduled = true
    self._scheduled_save = function()
        self._save_scheduled = false
        self._scheduled_save = nil
        self:saveData()
    end
    UIManager:scheduleIn(SAVE_DELAY, self._scheduled_save)
end

function CharacterTracker:loadData()
    self.characters = {}
    self.characters_sorted = false
    self._positions = nil
    self._name_index_dirty = true
    self._rel_index_dirty = true
    self._list_dirty = true

    local path = self:getDataFilePath()
    local f = io.open(path, "r")
    local series = self:getSeriesName()
    if not f and (not series or series == "") then
        local legacy_path = self.ui.document.file .. ".characters.json"
        f = io.open(legacy_path, "r")
        if f then path = legacy_path end
    end
    if f then
        local content = f:read("*all")
        f:close()
        if content and content ~= "" then
            local ok, data = pcall(json.decode, content)
            if ok and type(data) == "table" then
                self.characters = data
            else
                logger.warn("CharacterTracker: failed to parse", path)
            end
        end
    end

    if self:migrateData() then
        -- Persist the upgraded format on the next flush.
        self._dirty = true
        self:scheduleSave()
    end
    self:sortCharacters()
    self:ensureIndexes()
end

--- Bring older data files up to date: stable ids, relationships by id, notes
--- as plain strings. Returns true when something was rewritten.
function CharacterTracker:migrateData()
    local changed = false
    local seen_ids = {}
    local cleaned = {}

    for _i, char in ipairs(self.characters) do
        if type(char) == "table" then
            if type(char.name) ~= "string" or char.name == "" then
                char.name = tostring(char.name or "?")
                changed = true
            end
            if type(char.id) ~= "string" or char.id == "" or seen_ids[char.id] then
                char.id = self:newId()
                changed = true
            end
            seen_ids[char.id] = true

            if type(char.aliases) ~= "table" then
                char.aliases = {}
                changed = true
            end
            for i = #char.aliases, 1, -1 do
                if type(char.aliases[i]) ~= "string" then
                    table.remove(char.aliases, i)
                    changed = true
                end
            end

            if type(char.notes) ~= "table" then
                char.notes = {}
                changed = true
            end
            for i, note in ipairs(char.notes) do
                if type(note) == "table" then
                    char.notes[i] = getNoteText(note)
                    changed = true
                end
            end

            if type(char.relationships) ~= "table" then
                char.relationships = {}
                changed = true
            end

            local rating = tonumber(char.rating) or 0
            if char.rating ~= rating then
                char.rating = rating
                changed = true
            end
            if char.role == nil then
                char.role = ""
                changed = true
            end

            cleaned[#cleaned + 1] = char
        else
            changed = true
        end
    end
    if #cleaned ~= #self.characters then
        self.characters = cleaned
        changed = true
    end

    -- The name index is needed to resolve legacy relationships by name.
    self:rebuildNameIndex()

    for _i, char in ipairs(self.characters) do
        local kept = {}
        local rels = char.relationships
        for _j = 1, #rels do
            local rel = rels[_j]
            if type(rel) == "table" and type(rel.type) == "string" then
                local target = self:resolveRelationshipTarget(rel)
                if target and target.id ~= char.id then
                    if rel.target_id ~= target.id or rel.target ~= nil then
                        changed = true
                    end
                    kept[#kept + 1] = { target_id = target.id, type = rel.type }
                elseif rel.target and rel.target ~= "" then
                    -- Dangling name: keep it for display until it resolves.
                    if rel.target_id ~= nil then changed = true end
                    kept[#kept + 1] = { target = rel.target, type = rel.type }
                else
                    changed = true
                end
            else
                changed = true
            end
        end
        char.relationships = kept
    end

    if changed then
        self._name_index_dirty = true
        self._rel_index_dirty = true
        self._list_dirty = true
    end
    return changed
end

--- Atomic-ish write: the JSON is written to a temporary file first, then
--- renamed over the real one, so a crash mid-write cannot truncate the data.
function CharacterTracker:saveData(force)
    if not self._dirty and not force then return end
    self:cancelScheduledSave()

    self:sortCharacters()
    local path = self:getDataFilePath()
    if not path then return end
    local ok, content = pcall(json.encode, self.characters)
    if not ok then
        logger.warn("CharacterTracker: failed to encode data")
        return
    end

    local tmp = path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then
        logger.warn("CharacterTracker: cannot write", tmp)
        return
    end
    local written = f:write(content)
    f:close()
    if not written then
        os.remove(tmp)
        logger.warn("CharacterTracker: short write", tmp)
        return
    end

    -- os.rename() is atomic on POSIX but fails on FAT when the target exists.
    local saved = os.rename(tmp, path)
    if not saved then
        os.remove(path)
        saved = os.rename(tmp, path)
    end
    if not saved then
        -- Last resort: direct (non-atomic) write.
        local direct = io.open(path, "w")
        if direct then
            saved = direct:write(content)
            direct:close()
        end
        os.remove(tmp)
    end
    if not saved then
        logger.warn("CharacterTracker: failed to save", path)
        return
    end

    self._dirty = false
    self._series_cache = nil
end

--- Load characters from a specific file path (helper for merging)
function CharacterTracker:loadCharactersFromFile(path)
    local f = io.open(path, "r")
    if not f then return {} end
    local content = f:read("*all")
    f:close()
    if not content or content == "" then return {} end
    local ok, data = pcall(json.decode, content)
    if ok and type(data) == "table" then return data end
    return {}
end

--- Merge characters from source into current list (avoids duplicates by name)
function CharacterTracker:mergeCharacters(source_chars)
    self:ensureIndexes()
    local merged_count = 0
    local id_map = {}
    local added = {}

    for _i, src in ipairs(source_chars) do
        local existing = self:getCharacterByName(src.name)
        if existing then
            if src.id then id_map[src.id] = existing.id end
            -- Merge aliases
            if src.aliases then
                if not existing.aliases then existing.aliases = {} end
                local existing_aliases = {}
                for _j, existing_alias in ipairs(existing.aliases) do
                    existing_aliases[normalizeName(existing_alias)] = true
                end
                for _j, alias in ipairs(src.aliases) do
                    local alias_key = normalizeName(alias)
                    if alias_key ~= "" and not existing_aliases[alias_key] then
                        existing.aliases[#existing.aliases + 1] = alias
                        existing_aliases[alias_key] = true
                    end
                end
            end
            -- Merge notes (avoid exact duplicates)
            if src.notes then
                if not existing.notes then existing.notes = {} end
                local existing_notes = {}
                for _j, existing_note in ipairs(existing.notes) do
                    existing_notes[getNoteText(existing_note)] = true
                end
                for _j, note in ipairs(src.notes) do
                    local note_text = getNoteText(note)
                    if note_text ~= "" and not existing_notes[note_text] then
                        existing.notes[#existing.notes + 1] = note
                        existing_notes[note_text] = true
                    end
                end
            end
        else
            -- New character: keep its id unless it already exists here.
            local old_id = src.id
            if not old_id or old_id == "" or self.character_by_id[old_id] then
                src.id = self:newId()
            end
            if old_id then id_map[old_id] = src.id end

            self.characters[#self.characters + 1] = src
            local own_key = cachedNameKey(src)
            if own_key ~= "" then
                self.character_lookup[own_key] = src
            end
            self.character_by_id[src.id] = src
            if src.aliases then
                for _j, alias in ipairs(src.aliases) do
                    local alias_key = normalizeName(alias)
                    if alias_key ~= "" then
                        self.character_lookup[alias_key] = src
                    end
                end
            end
            added[#added + 1] = src
            merged_count = merged_count + 1
        end
    end

    -- Relationships inside the imported characters still reference the ids
    -- they had in the source database; remap them to the ids used here.
    for _i, char in ipairs(added) do
        if char.relationships then
            for _j, rel in ipairs(char.relationships) do
                if rel.target_id and id_map[rel.target_id] then
                    rel.target_id = id_map[rel.target_id]
                end
            end
        end
    end

    self.characters_sorted = false
    self._positions = nil
    self:markDirty("all")
    return merged_count
end

-- ============================================================
-- HELPERS
-- ============================================================

function CharacterTracker:getCharacterByName(name)
    self:ensureIndexes()
    return self.character_lookup[normalizeName(name)]
end

--- Position in self.characters, cached in a weak-keyed map so it stays O(1)
--- between structural changes.
function CharacterTracker:getCharacterIndex(character)
    local positions = self._positions
    if not positions then
        positions = setmetatable({}, { __mode = "k" })
        for i, char in ipairs(self.characters) do
            positions[char] = i
        end
        self._positions = positions
    end
    return positions[character]
end

function CharacterTracker:newId()
    id_sequence = id_sequence + 1
    return string.format("%x-%x-%x", os.time(), id_sequence, math.random(0, 0xFFFFFF))
end


-- ============================================================
-- ADD / EDIT / DELETE CHARACTERS
-- ============================================================

function CharacterTracker:addCharacter(name, note, callback)
    local existing = self:getCharacterByName(name)
    if existing then
        self:showCharacterDetail(existing)
        return
    end

    local character = {
        id = self:newId(),
        name = name,
        aliases = {},
        notes = {},
        relationships = {},
        rating = 0,
        role = "",
        created = os.date("%Y-%m-%d %H:%M"),
    }

    if note and note ~= "" then
        table.insert(character.notes, note)
    end

    self.characters[#self.characters + 1] = character
    self.characters_sorted = false
    self._positions = nil
    self:markDirty("names")

    UIManager:show(InfoMessage:new{
        text = T(_("Character '%1' added."), name),
        timeout = 2,
    })

    if callback then callback(character) end
end

function CharacterTracker:showAddCharacterDialog(preselected_name, callback)
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Add new character"),
        fields = {
            {
                text = preselected_name or "",
                hint = _("Character name"),
            },
            {
                text = "",
                hint = _("Note (optional) - e.g. role, description"),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Add"),
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        local name = fields[1]:match("^%s*(.-)%s*$") -- trim
                        local note = fields[2]:match("^%s*(.-)%s*$")
                        UIManager:close(dialog)
                        if name == "" then
                            UIManager:show(InfoMessage:new{
                                text = _("Name cannot be empty."),
                            })
                            return
                        end
                        self:addCharacter(name, note, callback)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function CharacterTracker:showNotesManager(character, on_close)
    local handle
    local function buildItems()
        local items = {}
        for i, note in ipairs(character.notes or {}) do
            local note_text = getNoteText(note)
            local short = note_text
            if #short > 60 then short = short:sub(1, 57) .. "..." end
            items[#items + 1] = {
                text = short,
                callback = function()
                    self:showNoteActionsDialog(character, i, handle.refresh)
                end,
            }
        end

        items[#items + 1] = {
            text = _("+ Add note"),
            callback = function()
                self:showAddNoteDialog(character, handle.refresh)
            end,
        }
        return items
    end

    handle = self:showMenu(T(_("Notes - %1"), character.name), buildItems, on_close)
end

function CharacterTracker:showNoteActionsDialog(character, note_index, on_done)
    local note = character.notes and character.notes[note_index]
    if not note then return end
    local note_text = getNoteText(note)
    local short = note_text
    if #short > 60 then short = short:sub(1, 57) .. "..." end

    local dialog
    dialog = ButtonDialog:new{
        title = short,
        buttons = {
            {
                {
                    text = _("Edit"),
                    callback = function()
                        UIManager:close(dialog)
                        self:showEditNoteDialog(character, note_index, on_done)
                    end,
                },
                {
                    text = _("Delete"),
                    callback = function()
                        UIManager:close(dialog)
                        self:confirmDeleteNote(character, note_index, on_done)
                    end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
        tap_close_callback = function() dialog = nil end,
    }
    UIManager:show(dialog)
end

function CharacterTracker:showAddNoteDialog(character, on_done)
    local dialog
    dialog = InputDialog:new{
        title = T(_("Add note to '%1'"), character.name),
        input_hint = _("Write your note here..."),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local text = dialog:getInputText():match("^%s*(.-)%s*$")
                        UIManager:close(dialog)
                        if text == "" then return end

                        character.notes = character.notes or {}
                        character.notes[#character.notes + 1] = text
                        self:markDirty()
                        UIManager:show(InfoMessage:new{
                            text = _("Note added."),
                            timeout = 1,
                        })
                        if on_done then on_done() end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function CharacterTracker:showEditNoteDialog(character, note_index, on_done)
    if not (character.notes and character.notes[note_index]) then return end
    local old_text = getNoteText(character.notes[note_index])

    local dialog
    dialog = InputDialog:new{
        title = _("Edit note"),
        input = old_text,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local text = dialog:getInputText():match("^%s*(.-)%s*$")
                        UIManager:close(dialog)
                        if text == "" then return end

                        character.notes[note_index] = text
                        self:markDirty()
                        UIManager:show(InfoMessage:new{
                            text = _("Note updated."),
                            timeout = 1,
                        })
                        if on_done then on_done() end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function CharacterTracker:confirmDeleteNote(character, note_index, on_done)
    if not (character.notes and character.notes[note_index]) then return end
    local note_text = getNoteText(character.notes[note_index])
    local short = note_text
    if #short > 50 then short = short:sub(1, 47) .. "..." end

    UIManager:show(ConfirmBox:new{
        text = T(_("Delete note?\n\n\"%1\""), short),
        ok_text = _("Delete"),
        ok_callback = function()
            table.remove(character.notes, note_index)
            self:markDirty()
            UIManager:show(InfoMessage:new{
                text = _("Note deleted."),
                timeout = 1,
            })
            if on_done then on_done() end
        end,
    })
end

function CharacterTracker:showAliasManager(character, on_close)
    if not character.aliases then
        character.aliases = {}
    end

    local handle
    local function buildItems()
        local items = {}
        for i, alias in ipairs(character.aliases) do
            local short = alias
            if #short > 50 then short = short:sub(1, 47) .. "..." end
            items[#items + 1] = {
                text = short,
                callback = function()
                    self:showAliasActionsDialog(character, i, handle.refresh)
                end,
            }
        end

        items[#items + 1] = {
            text = _("+ Add alias"),
            callback = function()
                self:showAddAliasDialog(character, handle.refresh)
            end,
        }
        return items
    end

    handle = self:showMenu(T(_("Aliases - %1"), character.name), buildItems, on_close)
end

function CharacterTracker:showAliasActionsDialog(character, alias_index, on_done)
    local alias = character.aliases[alias_index]
    if not alias then return end

    local dialog
    dialog = ButtonDialog:new{
        title = alias,
        buttons = {
            {
                {
                    text = _("Edit"),
                    callback = function()
                        UIManager:close(dialog)
                        self:showEditAliasDialog(character, alias_index, on_done)
                    end,
                },
                {
                    text = _("Delete"),
                    callback = function()
                        UIManager:close(dialog)
                        self:confirmDeleteAlias(character, alias_index, on_done)
                    end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
        tap_close_callback = function() dialog = nil end,
    }
    UIManager:show(dialog)
end

--- Check if an alias is already used by another character
function CharacterTracker:isAliasOrNameTaken(text, exclude_character)
    self:ensureIndexes()
    local taken_by = self.character_lookup[normalizeName(text)]
    if taken_by and taken_by ~= exclude_character then
        return taken_by.name
    end
    return nil
end

function CharacterTracker:showAddAliasDialog(character, on_done)
    local dialog
    dialog = InputDialog:new{
        title = T(_("Add alias for '%1'"), character.name),
        input_hint = _("Alias (nickname, title, etc.)"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Add"),
                    is_enter_default = true,
                    callback = function()
                        local alias = dialog:getInputText():match("^%s*(.-)%s*$")
                        UIManager:close(dialog)
                        if alias == "" then return end

                        local alias_key = normalizeName(alias)
                        if alias_key == cachedNameKey(character) then
                            UIManager:show(InfoMessage:new{
                                text = _("Alias cannot be the character name."),
                            })
                            return
                        end

                        -- Check for duplicates
                        local taken_by = self:isAliasOrNameTaken(alias, character)
                        if taken_by then
                            UIManager:show(InfoMessage:new{
                                text = T(_("'%1' is already used by '%2'."), alias, taken_by),
                            })
                            return
                        end

                        -- Check if same alias already exists on this character
                        if character.aliases then
                            for _i, existing in ipairs(character.aliases) do
                                if normalizeName(existing) == alias_key then
                                    UIManager:show(InfoMessage:new{
                                        text = T(_("Alias '%1' already exists."), alias),
                                    })
                                    return
                                end
                            end
                        end

                        character.aliases = character.aliases or {}
                        character.aliases[#character.aliases + 1] = alias
                        self:markDirty("names")
                        UIManager:show(InfoMessage:new{
                            text = T(_("Alias '%1' added."), alias),
                            timeout = 1,
                        })
                        if on_done then on_done() end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function CharacterTracker:showEditAliasDialog(character, alias_index, on_done)
    local old_alias = character.aliases[alias_index]
    local dialog
    dialog = InputDialog:new{
        title = _("Edit alias"),
        input = old_alias,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local alias = dialog:getInputText():match("^%s*(.-)%s*$")
                        UIManager:close(dialog)
                        if alias == "" then return end

                        local alias_key = normalizeName(alias)
                        -- Check for duplicates (exclude current value)
                        if alias_key ~= normalizeName(old_alias) then
                            local taken_by = self:isAliasOrNameTaken(alias, character)
                            if taken_by then
                                UIManager:show(InfoMessage:new{
                                    text = T(_("'%1' is already used by '%2'."), alias, taken_by),
                                })
                                return
                            end
                            -- Check within same character
                            for i, existing in ipairs(character.aliases) do
                                if i ~= alias_index and normalizeName(existing) == alias_key then
                                    UIManager:show(InfoMessage:new{
                                        text = T(_("Alias '%1' already exists."), alias),
                                    })
                                    return
                                end
                            end
                        end

                        character.aliases[alias_index] = alias
                        self:markDirty("names")
                        UIManager:show(InfoMessage:new{
                            text = T(_("Alias updated to '%1'."), alias),
                            timeout = 1,
                        })
                        if on_done then on_done() end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function CharacterTracker:confirmDeleteAlias(character, alias_index, on_done)
    local alias = character.aliases[alias_index]
    if not alias then return end
    UIManager:show(ConfirmBox:new{
        text = T(_("Delete alias '%1'?"), alias),
        ok_text = _("Delete"),
        ok_callback = function()
            table.remove(character.aliases, alias_index)
            self:markDirty("names")
            UIManager:show(InfoMessage:new{
                text = T(_("Alias '%1' deleted."), alias),
                timeout = 1,
            })
            if on_done then on_done() end
        end,
    })
end

-- ============================================================
-- RELATIONSHIPS
-- ============================================================

function CharacterTracker:showRelationshipManager(character, on_close)
    if not character.relationships then
        character.relationships = {}
    end

    local handle
    local function buildItems()
        local items = {}
        for i, rel in ipairs(character.relationships) do
            local label = getRelationshipLabel(rel.type)
            local target_name = self:getRelationshipTargetName(rel)
            local display = target_name .. " (" .. label .. ")"
            if #display > 50 then display = display:sub(1, 47) .. "..." end
            items[#items + 1] = {
                text = display,
                callback = function()
                    self:showRelationshipActionsDialog(character, i, handle.refresh)
                end,
            }
        end

        for _i, rel in ipairs(self:getIncomingRelationships(character)) do
            local label = getRelationshipLabel(rel.type)
            local source_name = self:getRelationshipSourceName(rel)
            local display = "← " .. source_name .. " (" .. label .. ")"
            if #display > 50 then display = display:sub(1, 47) .. "..." end
            local source = self.character_by_id[rel.source_id]
            local relationship_index = rel.relationship_index
            items[#items + 1] = {
                text = display,
                callback = function()
                    if source and source.relationships
                        and source.relationships[relationship_index] then
                        self:showRelationshipActionsDialog(source, relationship_index, handle.refresh)
                    end
                end,
            }
        end

        items[#items + 1] = {
            text = _("+ Add relationship"),
            callback = function()
                self:showAddRelationshipPicker(character, handle.refresh)
            end,
        }
        return items
    end

    handle = self:showMenu(T(_("Relationships - %1"), character.name), buildItems, on_close)
end

function CharacterTracker:showRelationshipActionsDialog(character, rel_index, on_done)
    local rel = character.relationships[rel_index]
    if not rel then return end
    self:ensureIndexes()

    local target = self:resolveRelationshipTarget(rel)
    local target_name = target and target.name or rel.target or _("Unknown")
    local label = getRelationshipLabel(rel.type)

    local dialog
    local buttons = {}
    if target then
        buttons[#buttons + 1] = {
            {
                text = T(_("Open '%1'"), target_name),
                callback = function()
                    UIManager:close(dialog)
                    self:showCharacterDetail(target)
                end,
            },
        }
        buttons[#buttons + 1] = {
            {
                text = _("Swap characters"),
                callback = function()
                    UIManager:close(dialog)
                    self:invertRelationship(character, rel_index, on_done)
                end,
            },
        }
    end
    buttons[#buttons + 1] = {
        {
            text = _("Delete"),
            callback = function()
                UIManager:close(dialog)
                self:confirmDeleteRelationship(character, rel_index, on_done)
            end,
        },
        {
            text = _("Cancel"),
            id = "close",
            callback = function()
                UIManager:close(dialog)
            end,
        },
    }

    dialog = ButtonDialog:new{
        title = T(_("%1 → %2 (%3)"), character.name, target_name, label),
        buttons = buttons,
        tap_close_callback = function() dialog = nil end,
    }
    UIManager:show(dialog)
end

--- Step 1: pick the target character
function CharacterTracker:showAddRelationshipPicker(character, on_done)
    local others = {}
    for _i, char in ipairs(self.characters) do
        if char ~= character then
            others[#others + 1] = char
        end
    end

    if #others == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No other characters to link. Add more characters first."),
        })
        return
    end

    local handle
    handle = self:showMenu(T(_("Add relationship from '%1' to…"), character.name), function()
        local items = {}
        for _i, char in ipairs(others) do
            items[#items + 1] = {
                text = char.name,
                callback = function()
                    handle.close()
                    self:showRelationshipTypePicker(character, char, on_done)
                end,
            }
        end
        return items
    end)
end

--- Step 2: pick the relationship type
function CharacterTracker:showRelationshipTypePicker(character, target, on_done)
    local buttons = {}
    local row = {}

    for _i, rt in ipairs(RELATIONSHIP_TYPES) do
        if rt.key == "custom" then
            -- Custom goes as its own row at the end
        else
            table.insert(row, {
                text = rt.label,
                callback = function()
                    UIManager:close(self._rel_type_picker)
                    self._rel_type_picker = nil
                    self:addRelationship(character, target, rt.key, on_done)
                end,
            })
            if #row >= 3 then
                table.insert(buttons, row)
                row = {}
            end
        end
    end
    if #row > 0 then
        table.insert(buttons, row)
    end

    -- Custom type button
    table.insert(buttons, {
        {
            text = _("Custom…"),
            callback = function()
                UIManager:close(self._rel_type_picker)
                self._rel_type_picker = nil
                self:showCustomRelationshipDialog(character, target, on_done)
            end,
        },
    })

    table.insert(buttons, {
        {
            text = _("Cancel"),
            id = "close",
            callback = function()
                UIManager:close(self._rel_type_picker)
                self._rel_type_picker = nil
            end,
        },
    })

    self._rel_type_picker = ButtonDialog:new{
        title = T(_("'%1' is ___ of '%2'"), target.name, character.name),
        buttons = buttons,
        tap_close_callback = function() self._rel_type_picker = nil end,
    }
    UIManager:show(self._rel_type_picker)
end

function CharacterTracker:showCustomRelationshipDialog(character, target, on_done)
    local dialog
    dialog = InputDialog:new{
        title = T(_("Custom relationship: '%1' → '%2'"), character.name, target.name),
        input_hint = _("Relationship (e.g. squire, rival, betrothed)"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Add"),
                    is_enter_default = true,
                    callback = function()
                        local rel_type = dialog:getInputText():match("^%s*(.-)%s*$")
                        UIManager:close(dialog)
                        if rel_type == "" then return end
                        self:addRelationship(character, target, rel_type, on_done)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function CharacterTracker:addRelationship(character, target, rel_type, on_done)
    if not character.relationships then
        character.relationships = {}
    end

    -- Check for duplicate
    for _i, rel in ipairs(character.relationships) do
        if rel.target_id == target.id and rel.type == rel_type then
            UIManager:show(InfoMessage:new{
                text = T(_("Relationship already exists.")),
            })
            return
        end
    end

    character.relationships[#character.relationships + 1] = {
        target_id = target.id,
        type = rel_type,
    }
    self:markDirty("rels")

    local label = getRelationshipLabel(rel_type)
    UIManager:show(InfoMessage:new{
        text = T(_("Added: '%1' — %2 → '%3'"), character.name, label, target.name),
        timeout = 2,
    })
    if on_done then on_done() end
end

function CharacterTracker:invertRelationship(character, rel_index, on_done)
    local rel = character.relationships[rel_index]
    if not rel then return end

    self:ensureIndexes()
    local target = self:resolveRelationshipTarget(rel)
    if not target then
        UIManager:show(InfoMessage:new{
            text = _("Cannot invert a relationship with an unknown character."),
        })
        return
    end

    for _i, existing in ipairs(target.relationships or {}) do
        if existing.type == rel.type and self:resolveRelationshipTarget(existing) == character then
            UIManager:show(InfoMessage:new{
                text = T(_("Relationship already exists.")),
            })
            if on_done then on_done() end
            return
        end
    end

    if not target.relationships then
        target.relationships = {}
    end
    target.relationships[#target.relationships + 1] = {
        target_id = character.id,
        type = rel.type,
    }
    table.remove(character.relationships, rel_index)
    self:markDirty("rels")

    UIManager:show(InfoMessage:new{
        text = T(_("Inverted: '%1' — %2 → '%3'"), target.name,
            getRelationshipLabel(rel.type), character.name),
        timeout = 2,
    })
    if on_done then on_done() end
end

function CharacterTracker:confirmDeleteRelationship(character, rel_index, on_done)
    local rel = character.relationships[rel_index]
    if not rel then return end
    local label = getRelationshipLabel(rel.type)

    UIManager:show(ConfirmBox:new{
        text = T(_("Delete relationship?\n\n%1 → %2 (%3)"), character.name,
            self:getRelationshipTargetName(rel), label),
        ok_text = _("Delete"),
        ok_callback = function()
            table.remove(character.relationships, rel_index)
            self:markDirty("rels")
            UIManager:show(InfoMessage:new{
                text = _("Relationship deleted."),
                timeout = 1,
            })
            if on_done then on_done() end
        end,
    })
end

--- Get all relationships pointing TO a character (from other characters)
function CharacterTracker:getIncomingRelationships(character)
    self:ensureIndexes()
    return self.incoming_relationship_lookup[character.id] or {}
end

function CharacterTracker:deleteCharacter(character)
    UIManager:show(ConfirmBox:new{
        text = T(_("Delete character '%1' and all associated data?"), character.name),
        ok_text = _("Delete"),
        ok_callback = function()
            local idx = self:getCharacterIndex(character)
            if idx then
                -- Also clean up relationships pointing to this character
                local deleted_id = character.id
                local deleted_key = cachedNameKey(character)
                for _i, char in ipairs(self.characters) do
                    local rels = char.relationships
                    if rels then
                        for j = #rels, 1, -1 do
                            local rel = rels[j]
                            if rel.target_id == deleted_id
                                or (rel.target and normalizeName(rel.target) == deleted_key) then
                                table.remove(rels, j)
                            end
                        end
                    end
                end
                table.remove(self.characters, idx)
                self.characters_sorted = false
                self._positions = nil
                self:markDirty("all")
                UIManager:show(InfoMessage:new{
                    text = T(_("Character '%1' deleted."), character.name),
                    timeout = 2,
                })
            end
        end,
    })
end

function CharacterTracker:showRenameDialog(character, on_done)
    local dialog
    dialog = InputDialog:new{
        title = T(_("Rename '%1'"), character.name),
        input = character.name,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Rename"),
                    is_enter_default = true,
                    callback = function()
                        local new_name = dialog:getInputText():match("^%s*(.-)%s*$")
                        UIManager:close(dialog)
                        if new_name == "" or new_name == character.name then return end

                        -- Check if new name conflicts with existing character
                        local taken_by = self:isAliasOrNameTaken(new_name, character)
                        if taken_by then
                            UIManager:show(InfoMessage:new{
                                text = T(_("'%1' is already used by '%2'."), new_name, taken_by),
                            })
                            return
                        end
                        local new_name_key = normalizeName(new_name)
                        if character.aliases then
                            for _i, alias in ipairs(character.aliases) do
                                if normalizeName(alias) == new_name_key then
                                    UIManager:show(InfoMessage:new{
                                        text = T(_("'%1' is already used by '%2'."), new_name, character.name),
                                    })
                                    return
                                end
                            end
                        end

                        local old_name = character.name

                        -- Relationships reference ids, so no scan is needed here.
                        character.name = new_name
                        normalized_name_cache[character] = nil
                        self.characters_sorted = false
                        self._positions = nil
                        self:markDirty("names")

                        UIManager:show(InfoMessage:new{
                            text = T(_("Renamed '%1' → '%2'."), old_name, new_name),
                            timeout = 2,
                        })

                        if on_done then on_done() end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- ============================================================
-- RATING & ROLE
-- ============================================================

function CharacterTracker:showRatingDialog(character, on_done)
    local buttons = {}
    local star_row = {}
    local dialog
    for i = 1, 5 do
        table.insert(star_row, {
            text = ("★"):rep(i),
            callback = function()
                UIManager:close(dialog)
                dialog = nil
                character.rating = i
                self:markDirty()
                if on_done then on_done() end
            end,
        })
    end
    table.insert(buttons, star_row)
    table.insert(buttons, {
        {
            text = _("Clear rating"),
            callback = function()
                UIManager:close(dialog)
                dialog = nil
                character.rating = 0
                self:markDirty()
                if on_done then on_done() end
            end,
        },
        {
            text = _("Cancel"),
            id = "close",
            callback = function()
                UIManager:close(dialog)
                dialog = nil
            end,
        },
    })
    dialog = ButtonDialog:new{
        title = T(_("Rate '%1'"), character.name),
        buttons = buttons,
        tap_close_callback = function() dialog = nil end,
    }
    UIManager:show(dialog)
end

function CharacterTracker:showRoleDialog(character, on_done)
    local buttons = {}
    local dialog
    for _i, role_def in ipairs(ROLES) do
        table.insert(buttons, {
            {
                text = role_def.label,
                callback = function()
                    UIManager:close(dialog)
                    dialog = nil
                    character.role = role_def.key
                    self:markDirty()
                    if on_done then on_done() end
                end,
            },
        })
    end
    table.insert(buttons, {
        {
            text = _("Cancel"),
            id = "close",
            callback = function()
                UIManager:close(dialog)
                dialog = nil
            end,
        },
    })
    dialog = ButtonDialog:new{
        title = T(_("Role of '%1'"), character.name),
        buttons = buttons,
        tap_close_callback = function() dialog = nil end,
    }
    UIManager:show(dialog)
end

-- ============================================================
-- CHARACTER DETAIL VIEW
-- ============================================================

function CharacterTracker:buildCharacterDetailText(character)
    self:ensureIndexes()
    local parts = {}
    local sep = "────────────────"

    parts[#parts + 1] = "  " .. _("Rating") .. ":  " .. starsString(character.rating) .. "\n"
    parts[#parts + 1] = "  " .. _("Role") .. ":    " .. getRoleLabel(character.role) .. "\n"

    if character.aliases and #character.aliases > 0 then
        parts[#parts + 1] = "  " .. _("Aliases") .. ": " .. table.concat(character.aliases, ", ") .. "\n"
    end

    local outgoing = character.relationships or {}
    local incoming = self:getIncomingRelationships(character)

    if #outgoing > 0 or #incoming > 0 then
        parts[#parts + 1] = sep .. "\n"
        parts[#parts + 1] = "  " .. _("Relationships") .. "\n"
        for _i, rel in ipairs(outgoing) do
            parts[#parts + 1] = "  → " .. self:getRelationshipTargetName(rel)
                .. " (" .. getRelationshipLabel(rel.type) .. ")\n"
        end
        for _i, rel in ipairs(incoming) do
            parts[#parts + 1] = "  ← " .. self:getRelationshipSourceName(rel)
                .. " (" .. getRelationshipLabel(rel.type) .. ")\n"
        end
    end

    -- Notes (general, not linked to pages)
    if character.notes and #character.notes > 0 then
        parts[#parts + 1] = sep .. "\n"
        parts[#parts + 1] = "  " .. _("Notes") .. " (" .. #character.notes .. ")\n"
        for _i, note in ipairs(character.notes) do
            parts[#parts + 1] = "  ◆ " .. getNoteText(note) .. "\n\n"
        end
    else
        parts[#parts + 1] = "\n  " .. _("No notes yet.") .. "\n"
    end

    return table.concat(parts)
end

function CharacterTracker:showCharacterDetail(character)
    local viewer
    local function refresh()
        if not viewer then return end
        viewer.text = self:buildCharacterDetailText(character)
        viewer:reinit()
    end

    viewer = TextViewer:new{
        title = character.name,
        text = self:buildCharacterDetailText(character),
        width = math.floor(Device.screen:getWidth() * 0.9),
        height = math.floor(Device.screen:getHeight() * 0.85),
        buttons_table = {
            {
                {
                    text = "★ " .. _("Rate"),
                    callback = function()
                        self:showRatingDialog(character, refresh)
                    end,
                },
                {
                    text = _("Role"),
                    callback = function()
                        self:showRoleDialog(character, refresh)
                    end,
                },
                {
                    text = _("Notes"),
                    callback = function()
                        self:showNotesManager(character, refresh)
                    end,
                },
            },
            {
                {
                    text = _("Aliases"),
                    callback = function()
                        self:showAliasManager(character, refresh)
                    end,
                },
                {
                    text = _("Relations"),
                    callback = function()
                        self:showRelationshipManager(character, refresh)
                    end,
                },
            },
            {
                {
                    text = _("Rename"),
                    callback = function()
                        self:showRenameDialog(character, function()
                            -- The title bar changes with the name: rebuild.
                            UIManager:close(viewer)
                            self:showCharacterDetail(character)
                        end)
                    end,
                },
                {
                    text = _("Delete"),
                    callback = function()
                        UIManager:close(viewer)
                        self:deleteCharacter(character)
                    end,
                },
                {
                    text = _("Close"),
                    id = "close",
                    callback = function()
                        UIManager:close(viewer)
                    end,
                },
            },
        },
    }
    UIManager:show(viewer)
end

-- ============================================================
-- CHARACTER LIST
-- ============================================================

--- Build a scrollable menu over the current page. Used for every list that can
--- grow with the number of characters, notes, aliases or series: a
--- ButtonDialog would instantiate one widget per row up front.
--- Returns a handle with refresh() and close().
function CharacterTracker:showMenu(title, build_items, on_close)
    local menu_container
    local menu
    local closed = false

    local function close()
        if closed then return end
        closed = true
        UIManager:close(menu_container)
        if on_close then on_close() end
    end

    menu = Menu:new{
        title = title,
        item_table = build_items(),
        is_borderless = true,
        is_popout = false,
        covers_fullscreen_widget = true,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        onMenuSelect = function(_self, item)
            if item.callback then item.callback() end
        end,
        close_callback = close,
    }
    menu_container = CenterContainer:new{
        dimen = Screen:getSize(),
        menu,
    }
    menu.show_parent = menu_container
    UIManager:show(menu_container)

    return {
        menu = menu,
        refresh = function()
            if closed then return end
            menu:switchItemTable(title, build_items(), 1)
        end,
        close = close,
    }
end

function CharacterTracker:onShowCharacterList()
    self:showCharacterList()
end

function CharacterTracker:showCharacterList()
    if not self.characters or #self.characters == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No characters tracked yet.\n\nTo add a character:\n1. Select text in the book\n2. Tap 'Character' in the highlight menu\n3. Or use the Tools menu → Character Tracker → Add character"),
        })
        return
    end

    self:ensureIndexes()
    local item_table = self.character_list_cache
    if self._list_dirty or not item_table then
        item_table = {}
        for _i, char in ipairs(self.characters) do
            local badges = {}
            -- Stars
            local rating = char.rating or 0
            if rating > 0 then
                badges[#badges + 1] = ("★"):rep(rating)
            end
            -- Role
            local role = char.role or ""
            if role ~= "" then
                badges[#badges + 1] = getRoleLabel(role)
            end
            -- Aliases
            if char.aliases and #char.aliases > 0 then
                badges[#badges + 1] = T(_("%1 aliases"), #char.aliases)
            end
            -- Relationships
            local rel_count = (char.relationships and #char.relationships or 0)
                + #self:getIncomingRelationships(char)
            if rel_count > 0 then
                badges[#badges + 1] = T(_("%1 relations"), rel_count)
            end
            -- Counts
            if char.notes and #char.notes > 0 then
                badges[#badges + 1] = T(_("%1 notes"), #char.notes)
            end
            local info = ""
            if #badges > 0 then
                info = "  " .. table.concat(badges, " · ")
            end

            -- Show aliases below the name
            local display_name = char.name
            if char.aliases and #char.aliases > 0 then
                display_name = char.name .. "\n    aka: " .. table.concat(char.aliases, ", ")
            end

            item_table[#item_table + 1] = {
                text = display_name .. info,
                character = char,
                callback = function()
                    self:showCharacterDetail(char)
                end,
            }
        end
        self.character_list_cache = item_table
        self._list_dirty = false
    end

    local menu_container
    local menu
    menu = Menu:new{
        title = _("Characters"),
        item_table = item_table,
        is_borderless = true,
        is_popout = false,
        covers_fullscreen_widget = true,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        onMenuSelect = function(_self, item)
            if item.callback then item.callback() end
        end,
        close_callback = function()
            UIManager:close(menu_container)
        end,
    }
    menu_container = CenterContainer:new{
        dimen = Screen:getSize(),
        menu,
    }
    menu.show_parent = menu_container
    UIManager:show(menu_container)
end

-- ============================================================
-- HIGHLIGHT INTEGRATION
-- ============================================================

function CharacterTracker:onAssignHighlightToCharacter(selected)
    if not selected then
        UIManager:show(InfoMessage:new{
            text = _("No text selected."),
        })
        return
    end

    local selected_text = selected.text or ""

    -- Check if selected text matches an existing character name or alias
    local trimmed = selected_text:match("^%s*(.-)%s*$")
    local existing = self:getCharacterByName(trimmed)
    if existing then
        self:showCharacterDetail(existing)
        return
    end

    if trimmed == "" then
        UIManager:show(InfoMessage:new{
            text = _("No text selected."),
        })
        return
    end

    -- Create the character directly, then show its detail page.
    self:addCharacter(trimmed, nil, function(character)
        self:showCharacterDetail(character)
    end)
end

-- ============================================================
-- SERIES MANAGEMENT
-- ============================================================

function CharacterTracker:showLinkSeriesDialog()
    local available = self:getAvailableSeries()

    -- If there are existing series, show picker first
    if #available > 0 then
        local handle
        local function buildItems()
            local items = {}
            for _i, s in ipairs(available) do
                items[#items + 1] = {
                    text = T(_("%1 (%2 characters)"), s.name, s.count),
                    callback = function()
                        handle.close()
                        self:linkToSeries(s.name)
                    end,
                }
            end
            items[#items + 1] = {
                text = _("＋ New series"),
                callback = function()
                    handle.close()
                    self:showNewSeriesDialog()
                end,
            }
            items[#items + 1] = {
                text = _("Delete a series…"),
                callback = function()
                    handle.close()
                    self:showDeleteSeriesDialog()
                end,
            }
            return items
        end
        handle = self:showMenu(_("Link book to series"), buildItems)
    else
        -- No existing series, go straight to create
        self:showNewSeriesDialog()
    end
end

function CharacterTracker:showDeleteSeriesDialog()
    local handle
    local function buildItems()
        local items = {}
        for _i, s in ipairs(self:getAvailableSeries()) do
            items[#items + 1] = {
                text = T(_("%1 (%2 characters)"), s.name, s.count),
                callback = function()
                    self:confirmDeleteSeries(s, handle.refresh)
                end,
            }
        end
        if #items == 0 then
            items[#items + 1] = {
                text = _("No series to delete."),
                callback = function() handle.close() end,
            }
        end
        return items
    end
    handle = self:showMenu(_("Delete a series"), buildItems)
end

function CharacterTracker:showNewSeriesDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("New series"),
        input_hint = _("Series name (e.g. A Song of Ice and Fire)"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Create & link"),
                    is_enter_default = true,
                    callback = function()
                        local series = dialog:getInputText():match("^%s*(.-)%s*$")
                        UIManager:close(dialog)
                        if series == "" then
                            UIManager:show(InfoMessage:new{
                                text = _("Series name cannot be empty."),
                            })
                            return
                        end
                        self:linkToSeries(series)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function CharacterTracker:linkToSeries(series_name)
    -- Flush any pending edit to the current (per-book) file before switching.
    self:saveData(true)

    local old_characters = self.characters
    local had_characters = #old_characters > 0

    -- Switch to series storage
    self:setSeriesName(series_name)
    self:loadData()

    local series_had_characters = #self.characters > 0

    if had_characters then
        -- Merge old book characters into series
        local merged = self:mergeCharacters(old_characters)
        self:saveData(true)

        local msg
        if series_had_characters then
            msg = T(_("Linked to series '%1'.\nMerged characters: %2 new added, %3 already in series."),
                series_name, merged, #old_characters - merged)
        else
            msg = T(_("Linked to series '%1'.\n%2 characters moved to shared series."),
                series_name, #self.characters)
        end
        UIManager:show(InfoMessage:new{ text = msg })
    else
        if series_had_characters then
            UIManager:show(InfoMessage:new{
                text = T(_("Linked to series '%1'.\nLoaded %2 shared characters."),
                    series_name, #self.characters),
            })
        else
            UIManager:show(InfoMessage:new{
                text = T(_("Linked to series '%1'.\nNo characters yet — they will be shared across all books in this series."),
                    series_name),
            })
        end
    end
end

function CharacterTracker:unlinkFromSeries()
    local series = self:getSeriesName()
    if not series or series == "" then return end

    UIManager:show(ConfirmBox:new{
        text = T(_("Unlink this book from series '%1'?\n\nThe shared series characters will remain in the series. This book will go back to its own character list."), series),
        ok_text = _("Unlink"),
        ok_callback = function()
            -- Flush pending edits to the series file before switching back.
            self:saveData(true)
            self:setSeriesName(nil)
            -- Reload the per-book file instead of overwriting it with an empty
            -- list: the characters tracked before linking are still there.
            self:loadData()
            UIManager:show(InfoMessage:new{
                text = T(_("Unlinked from series '%1'."), series),
                timeout = 2,
            })
        end,
    })
end

--- List all available series files
function CharacterTracker:getAvailableSeries()
    if self._series_cache then return self._series_cache end

    local series = {}
    local dir = self:getSeriesDir()
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if ok then
        for entry in iter, dir_obj do
            if entry ~= "." and entry ~= ".." and entry:match("%.json$") then
                local path = dir .. "/" .. entry
                local chars = self:loadCharactersFromFile(path)
                series[#series + 1] = {
                    name = seriesNameFromFile(entry),
                    path = path,
                    count = #chars,
                }
            end
        end
    end
    table.sort(series, function(a, b) return a.name < b.name end)
    self._series_cache = series
    return series
end

-- ============================================================
-- MENU REGISTRATION
-- ============================================================

function CharacterTracker:addToMainMenu(menu_items)
    menu_items.character_tracker = {
        text = _("Character Tracker"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Character list"),
                keep_menu_open = false,
                callback = function()
                    self:showCharacterList()
                end,
            },
            {
                text = _("Add character"),
                keep_menu_open = false,
                callback = function()
                    self:showAddCharacterDialog()
                end,
            },
            {
                text = _("Link to series"),
                keep_menu_open = false,
                callback = function()
                    local series = self:getSeriesName()
                    if series and series ~= "" then
                        self:showSeriesOptions()
                    else
                        self:showLinkSeriesDialog()
                    end
                end,
            },
        },
    }
end

function CharacterTracker:confirmDeleteSeries(s, on_done)
    UIManager:show(ConfirmBox:new{
        text = T(_("Delete series '%1'?\n\nThis will permanently remove the shared character file (%2 characters). Books currently linked to this series will lose access to its characters."), s.name, s.count),
        ok_text = _("Delete"),
        ok_callback = function()
            os.remove(s.path)
            self._series_cache = nil
            -- If the current book is linked to this series, unlink it
            local current = self:getSeriesName()
            if current == s.name then
                self:setSeriesName(nil)
                self:loadData()
            end
            UIManager:show(InfoMessage:new{
                text = T(_("Deleted series '%1'."), s.name),
                timeout = 2,
            })
            if on_done then on_done() end
        end,
    })
end

function CharacterTracker:showSeriesOptions()
    local series = self:getSeriesName()
    local buttons = {
        {
            {
                text = _("Change series name"),
                callback = function()
                    UIManager:close(self._series_dialog)
                    self._series_dialog = nil
                    self:showLinkSeriesDialog()
                end,
            },
        },
        {
            {
                text = _("Unlink from series"),
                callback = function()
                    UIManager:close(self._series_dialog)
                    self._series_dialog = nil
                    self:unlinkFromSeries()
                end,
            },
        },
        {
            {
                text = _("Close"),
                id = "close",
                callback = function()
                    UIManager:close(self._series_dialog)
                    self._series_dialog = nil
                end,
            },
        },
    }
    self._series_dialog = ButtonDialog:new{
        title = T(_("Series: %1\n%2 shared characters"), series, #self.characters),
        buttons = buttons,
    }
    UIManager:show(self._series_dialog)
end

return CharacterTracker
