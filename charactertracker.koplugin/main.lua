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
    incoming_relationship_lookup = nil,
    character_list_cache = nil,
    characters_sorted = false,
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

local function starsString(rating)
    rating = rating or 0
    if rating == 0 then return _("No rating") end
    return ("★"):rep(rating) .. ("☆"):rep(5 - rating)
end

-- ============================================================
-- INIT / LIFECYCLE
-- ============================================================

function CharacterTracker:init()
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
    self.characters = {}
    self.character_lookup = {}
    self.incoming_relationship_lookup = {}
    self.character_list_cache = nil
    self.characters_sorted = false
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

-- ============================================================
-- DATA PERSISTENCE
-- ============================================================

function CharacterTracker:getSeriesDir()
    local dir = DataStorage:getDataDir() .. "/character_tracker"
    lfs.mkdir(dir)
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
end

function CharacterTracker:getDataFilePath()
    if self.data_file then return self.data_file end
    local series = self:getSeriesName()
    if series and series ~= "" then
        -- Sanitize series name for filename
        local safe_name = series:gsub("[^%w%s%-_]", ""):gsub("%s+", "_")
        self.data_file = self:getSeriesDir() .. "/" .. safe_name .. ".json"
    else
        local doc_path = self.ui.document.file
        local sidecar_dir = DocSettings:getSidecarDir(doc_path)
        local filename = doc_path:match("[^/]+$") or doc_path
        self.data_file = sidecar_dir .. "/" .. "characters.json"
    end
    return self.data_file
end

function CharacterTracker:sortCharacters()
    if self.characters_sorted then return end
    table.sort(self.characters, function(a, b)
        local a_name = normalizeName(a.name)
        local b_name = normalizeName(b.name)
        if a_name == b_name then
            return a.name < b.name
        end
        return a_name < b_name
    end)
    self.characters_sorted = true
end

function CharacterTracker:rebuildCaches()
    self.character_lookup = {}
    self.incoming_relationship_lookup = {}

    for _i, char in ipairs(self.characters) do
        self.character_lookup[normalizeName(char.name)] = char
        if char.aliases then
            for _j, alias in ipairs(char.aliases) do
                self.character_lookup[normalizeName(alias)] = char
            end
        end
    end

    for _i, char in ipairs(self.characters) do
        if char.relationships then
            for _j, rel in ipairs(char.relationships) do
                local target = normalizeName(rel.target)
                if target ~= "" and target ~= normalizeName(char.name) then
                    local incoming = self.incoming_relationship_lookup[target]
                    if not incoming then
                        incoming = {}
                        self.incoming_relationship_lookup[target] = incoming
                    end
                    table.insert(incoming, {
                        source = char.name,
                        type = rel.type,
                    })
                end
            end
        end
    end

    self.character_list_cache = nil
end

function CharacterTracker:loadData()
    self.characters = {}
    self.characters_sorted = false
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
            if ok and data then
                self.characters = data
            else
                logger.warn("CharacterTracker: failed to parse", path)
            end
        end
    end
    self:sortCharacters()
    self:rebuildCaches()
end

function CharacterTracker:saveData()
    self:sortCharacters()
    self:rebuildCaches()
    local path = self:getDataFilePath()
    local ok, content = pcall(json.encode, self.characters)
    if ok then
        local f = io.open(path, "w")
        if f then
            f:write(content)
            f:close()
        end
    else
        logger.warn("CharacterTracker: failed to encode data")
    end
end

--- Load characters from a specific file path (helper for merging)
function CharacterTracker:loadCharactersFromFile(path)
    local f = io.open(path, "r")
    if not f then return {} end
    local content = f:read("*all")
    f:close()
    if not content or content == "" then return {} end
    local ok, data = pcall(json.decode, content)
    if ok and data then return data end
    return {}
end

--- Merge characters from source into current list (avoids duplicates by name)
function CharacterTracker:mergeCharacters(source_chars)
    local merged_count = 0
    for _i, src in ipairs(source_chars) do
        local existing = self:getCharacterByName(src.name)
        if existing then
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
                        table.insert(existing.aliases, alias)
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
                        table.insert(existing.notes, note)
                        existing_notes[note_text] = true
                    end
                end
            end
        else
            -- New character, add it
            table.insert(self.characters, src)
            self.character_lookup = self.character_lookup or {}
            self.character_lookup[normalizeName(src.name)] = src
            if src.aliases then
                for _j, alias in ipairs(src.aliases) do
                    self.character_lookup[normalizeName(alias)] = src
                end
            end
            merged_count = merged_count + 1
        end
    end
    self.characters_sorted = false
    return merged_count
end

-- ============================================================
-- HELPERS
-- ============================================================

function CharacterTracker:getCurrentPage()
    return self.ui:getCurrentPage()
end

function CharacterTracker:getCurrentChapter()
    local page
    if self.ui.rolling then
        page = self.ui.document:getXPointer()
    else
        page = self:getCurrentPage()
    end
    local toc_title = self.ui.toc:getTocTitleByPage(page)
    return toc_title or _("Unknown chapter")
end

function CharacterTracker:getCharacterByName(name)
    if not self.character_lookup then return nil end
    return self.character_lookup[normalizeName(name)]
end

function CharacterTracker:getCharacterIndex(character)
    for i, char in ipairs(self.characters) do
        if char == character then
            return i
        end
    end
    return nil
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

    table.insert(self.characters, character)
    self.characters_sorted = false
    self:saveData()

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

function CharacterTracker:showNotesManager(character)
    local buttons = {}

    -- One button per note with edit/delete
    for i, note in ipairs(character.notes or {}) do
        local note_text = getNoteText(note)
        local short = note_text
        if #short > 40 then short = short:sub(1, 37) .. "..." end

        table.insert(buttons, {
            {
                text = short,
                callback = function()
                    UIManager:close(self._notes_dialog)
                    self._notes_dialog = nil
                    self:showEditNoteDialog(character, i)
                end,
            },
            {
                text = "✕",
                callback = function()
                    UIManager:close(self._notes_dialog)
                    self._notes_dialog = nil
                    self:confirmDeleteNote(character, i)
                end,
            },
        })
    end

    -- Add new note button
    table.insert(buttons, {
        {
            text = _("+ Add note"),
            callback = function()
                UIManager:close(self._notes_dialog)
                self._notes_dialog = nil
                self:showAddNoteDialog(character)
            end,
        },
        {
            text = _("Close"),
            id = "close",
            callback = function()
                UIManager:close(self._notes_dialog)
                self._notes_dialog = nil
            end,
        },
    })

    self._notes_dialog = ButtonDialog:new{
        title = T(_("Notes - %1"), character.name),
        buttons = buttons,
    }
    UIManager:show(self._notes_dialog)
end

function CharacterTracker:showAddNoteDialog(character)
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

                        table.insert(character.notes, text)
                        self:saveData()
                        UIManager:show(InfoMessage:new{
                            text = _("Note added."),
                            timeout = 1,
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function CharacterTracker:showEditNoteDialog(character, note_index)
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
                        self:saveData()
                        UIManager:show(InfoMessage:new{
                            text = _("Note updated."),
                            timeout = 1,
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function CharacterTracker:confirmDeleteNote(character, note_index)
    local note_text = getNoteText(character.notes[note_index])
    local short = note_text
    if #short > 50 then short = short:sub(1, 47) .. "..." end

    UIManager:show(ConfirmBox:new{
        text = T(_("Delete note?\n\n\"%1\""), short),
        ok_text = _("Delete"),
        ok_callback = function()
            table.remove(character.notes, note_index)
            self:saveData()
            UIManager:show(InfoMessage:new{
                text = _("Note deleted."),
                timeout = 1,
            })
        end,
    })
end

function CharacterTracker:showAliasManager(character)
    if not character.aliases then
        character.aliases = {}
    end

    local buttons = {}

    -- One row per alias with edit and delete
    for i, alias in ipairs(character.aliases) do
        local short = alias
        if #short > 35 then short = short:sub(1, 32) .. "..." end

        table.insert(buttons, {
            {
                text = short,
                callback = function()
                    UIManager:close(self._alias_dialog)
                    self._alias_dialog = nil
                    self:showEditAliasDialog(character, i)
                end,
            },
            {
                text = "✕",
                callback = function()
                    UIManager:close(self._alias_dialog)
                    self._alias_dialog = nil
                    self:confirmDeleteAlias(character, i)
                end,
            },
        })
    end

    -- Add new alias button
    table.insert(buttons, {
        {
            text = _("+ Add alias"),
            callback = function()
                UIManager:close(self._alias_dialog)
                self._alias_dialog = nil
                self:showAddAliasDialog(character)
            end,
        },
        {
            text = _("Close"),
            id = "close",
            callback = function()
                UIManager:close(self._alias_dialog)
                self._alias_dialog = nil
            end,
        },
    })

    self._alias_dialog = ButtonDialog:new{
        title = T(_("Aliases - %1"), character.name),
        buttons = buttons,
    }
    UIManager:show(self._alias_dialog)
end

--- Check if an alias is already used by another character
function CharacterTracker:isAliasOrNameTaken(text, exclude_character)
    local taken_by = self.character_lookup and
        self.character_lookup[normalizeName(text)]
    if taken_by and taken_by ~= exclude_character then
        return taken_by.name
    end
    return nil
end

function CharacterTracker:showAddAliasDialog(character)
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
                        if normalizeName(alias) == normalizeName(character.name) then
                            UIManager:show(InfoMessage:new{
                                text = _("Alias cannot be the character name."),
                            })
                            return
                        end
                        if normalizeName(alias) == normalizeName(character.name) then
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
                                if normalizeName(existing) == normalizeName(alias) then
                                    UIManager:show(InfoMessage:new{
                                        text = T(_("Alias '%1' already exists."), alias),
                                    })
                                    return
                                end
                            end
                        end

                        if not character.aliases then
                            character.aliases = {}
                        end

                        table.insert(character.aliases, alias)
                        self:saveData()
                        UIManager:show(InfoMessage:new{
                            text = T(_("Alias '%1' added."), alias),
                            timeout = 1,
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function CharacterTracker:showEditAliasDialog(character, alias_index)
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

                        -- Check for duplicates (exclude current value)
                        if normalizeName(alias) ~= normalizeName(old_alias) then
                            local taken_by = self:isAliasOrNameTaken(alias, character)
                            if taken_by then
                                UIManager:show(InfoMessage:new{
                                    text = T(_("'%1' is already used by '%2'."), alias, taken_by),
                                })
                                return
                            end
                            -- Check within same character
                            for i, existing in ipairs(character.aliases) do
                                if i ~= alias_index and normalizeName(existing) == normalizeName(alias) then
                                    UIManager:show(InfoMessage:new{
                                        text = T(_("Alias '%1' already exists."), alias),
                                    })
                                    return
                                end
                            end
                        end

                        character.aliases[alias_index] = alias
                        self:saveData()
                        UIManager:show(InfoMessage:new{
                            text = T(_("Alias updated to '%1'."), alias),
                            timeout = 1,
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function CharacterTracker:confirmDeleteAlias(character, alias_index)
    local alias = character.aliases[alias_index]
    UIManager:show(ConfirmBox:new{
        text = T(_("Delete alias '%1'?"), alias),
        ok_text = _("Delete"),
        ok_callback = function()
            table.remove(character.aliases, alias_index)
            self:saveData()
            UIManager:show(InfoMessage:new{
                text = T(_("Alias '%1' deleted."), alias),
                timeout = 1,
            })
        end,
    })
end

-- ============================================================
-- RELATIONSHIPS
-- ============================================================

function CharacterTracker:showRelationshipManager(character)
    if not character.relationships then
        character.relationships = {}
    end

    local buttons = {}

    for i, rel in ipairs(character.relationships) do
        local label = getRelationshipLabel(rel.type)
        local display = rel.target .. " (" .. label .. ")"
        if #display > 38 then display = display:sub(1, 35) .. "..." end

        table.insert(buttons, {
            {
                text = display,
                callback = function()
                    UIManager:close(self._rel_dialog)
                    self._rel_dialog = nil
                    -- Tap on relationship: navigate to that character's detail
                    local target_char = self:getCharacterByName(rel.target)
                    if target_char then
                        self:showCharacterDetail(target_char)
                    else
                        UIManager:show(InfoMessage:new{
                            text = T(_("Character '%1' not found."), rel.target),
                        })
                    end
                end,
            },
            {
                text = "✕",
                callback = function()
                    UIManager:close(self._rel_dialog)
                    self._rel_dialog = nil
                    self:confirmDeleteRelationship(character, i)
                end,
            },
        })
    end

    table.insert(buttons, {
        {
            text = _("+ Add relationship"),
            callback = function()
                UIManager:close(self._rel_dialog)
                self._rel_dialog = nil
                self:showAddRelationshipPicker(character)
            end,
        },
        {
            text = _("Close"),
            id = "close",
            callback = function()
                UIManager:close(self._rel_dialog)
                self._rel_dialog = nil
            end,
        },
    })

    self._rel_dialog = ButtonDialog:new{
        title = T(_("Relationships - %1"), character.name),
        buttons = buttons,
    }
    UIManager:show(self._rel_dialog)
end

--- Step 1: pick the target character
function CharacterTracker:showAddRelationshipPicker(character)
    local buttons = {}
    local row = {}

    for _i, char in ipairs(self.characters) do
        if char.name ~= character.name then
            table.insert(row, {
                text = char.name,
                callback = function()
                    UIManager:close(self._rel_picker)
                    self._rel_picker = nil
                    self:showRelationshipTypePicker(character, char.name)
                end,
            })
            if #row >= 2 then
                table.insert(buttons, row)
                row = {}
            end
        end
    end
    if #row > 0 then
        table.insert(buttons, row)
    end

    if #buttons == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No other characters to link. Add more characters first."),
        })
        return
    end

    table.insert(buttons, {
        {
            text = _("Cancel"),
            id = "close",
            callback = function()
                UIManager:close(self._rel_picker)
                self._rel_picker = nil
            end,
        },
    })

    self._rel_picker = ButtonDialog:new{
        title = T(_("Add relationship from '%1' to…"), character.name),
        buttons = buttons,
    }
    UIManager:show(self._rel_picker)
end

--- Step 2: pick the relationship type
function CharacterTracker:showRelationshipTypePicker(character, target_name)
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
                    self:addRelationship(character, target_name, rt.key)
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
                self:showCustomRelationshipDialog(character, target_name)
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
        title = T(_("'%1' is ___ of '%2'"), target_name, character.name),
        buttons = buttons,
    }
    UIManager:show(self._rel_type_picker)
end

function CharacterTracker:showCustomRelationshipDialog(character, target_name)
    local dialog
    dialog = InputDialog:new{
        title = T(_("Custom relationship: '%1' → '%2'"), character.name, target_name),
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
                        self:addRelationship(character, target_name, rel_type)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function CharacterTracker:addRelationship(character, target_name, rel_type)
    if not character.relationships then
        character.relationships = {}
    end

    -- Check for duplicate
    local target_key = normalizeName(target_name)
    for _i, rel in ipairs(character.relationships) do
        if normalizeName(rel.target) == target_key and rel.type == rel_type then
            UIManager:show(InfoMessage:new{
                text = T(_("Relationship already exists.")),
            })
            return
        end
    end

    table.insert(character.relationships, {
        target = target_name,
        type = rel_type,
    })
    self:saveData()

    local label = getRelationshipLabel(rel_type)
    UIManager:show(InfoMessage:new{
        text = T(_("Added: '%1' — %2 → '%3'"), character.name, label, target_name),
        timeout = 2,
    })
end

function CharacterTracker:confirmDeleteRelationship(character, rel_index)
    local rel = character.relationships[rel_index]
    local label = getRelationshipLabel(rel.type)

    UIManager:show(ConfirmBox:new{
        text = T(_("Delete relationship?\n\n%1 → %2 (%3)"), character.name, rel.target, label),
        ok_text = _("Delete"),
        ok_callback = function()
            table.remove(character.relationships, rel_index)
            self:saveData()
            UIManager:show(InfoMessage:new{
                text = _("Relationship deleted."),
                timeout = 1,
            })
        end,
    })
end

--- Get all relationships pointing TO a character (from other characters)
function CharacterTracker:getIncomingRelationships(character)
    if not self.incoming_relationship_lookup then return {} end
    return self.incoming_relationship_lookup[normalizeName(character.name)] or {}
end

function CharacterTracker:deleteCharacter(character)
    UIManager:show(ConfirmBox:new{
        text = T(_("Delete character '%1' and all associated data?"), character.name),
        ok_text = _("Delete"),
        ok_callback = function()
            local idx = self:getCharacterIndex(character)
            if idx then
                -- Also clean up relationships pointing to this character
                local char_name_lower = normalizeName(character.name)
                for _i, char in ipairs(self.characters) do
                    if char.relationships then
                        for j = #char.relationships, 1, -1 do
                            if normalizeName(char.relationships[j].target) == char_name_lower then
                                table.remove(char.relationships, j)
                            end
                        end
                    end
                end
                table.remove(self.characters, idx)
                self.characters_sorted = false
                self:saveData()
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
                        local old_name_lower = normalizeName(old_name)

                        -- Update relationships in other characters that point to this one
                        for _i, char in ipairs(self.characters) do
                            if char.relationships then
                                for _j, rel in ipairs(char.relationships) do
                                    if normalizeName(rel.target) == old_name_lower then
                                        rel.target = new_name
                                    end
                                end
                            end
                        end

                        character.name = new_name
                        self.characters_sorted = false
                        self:saveData()

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
    for i = 1, 5 do
        table.insert(star_row, {
            text = ("★"):rep(i),
            callback = function()
                UIManager:close(self._rating_dialog)
                self._rating_dialog = nil
                character.rating = i
                self:saveData()
                if on_done then on_done() end
            end,
        })
    end
    table.insert(buttons, star_row)
    table.insert(buttons, {
        {
            text = _("Clear rating"),
            callback = function()
                UIManager:close(self._rating_dialog)
                self._rating_dialog = nil
                character.rating = 0
                self:saveData()
                if on_done then on_done() end
            end,
        },
        {
            text = _("Cancel"),
            id = "close",
            callback = function()
                UIManager:close(self._rating_dialog)
                self._rating_dialog = nil
            end,
        },
    })
    self._rating_dialog = ButtonDialog:new{
        title = T(_("Rate '%1'"), character.name),
        buttons = buttons,
    }
    UIManager:show(self._rating_dialog)
end

function CharacterTracker:showRoleDialog(character, on_done)
    local buttons = {}
    for _i, role_def in ipairs(ROLES) do
        table.insert(buttons, {
            {
                text = role_def.label,
                callback = function()
                    UIManager:close(self._role_dialog)
                    self._role_dialog = nil
                    character.role = role_def.key
                    self:saveData()
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
                UIManager:close(self._role_dialog)
                self._role_dialog = nil
            end,
        },
    })
    self._role_dialog = ButtonDialog:new{
        title = T(_("Role of '%1'"), character.name),
        buttons = buttons,
    }
    UIManager:show(self._role_dialog)
end

-- ============================================================
-- CHARACTER DETAIL VIEW
-- ============================================================

function CharacterTracker:showCharacterDetail(character)
    local text_parts = {}
    local sep = "────────────────"

    -- Header
    table.insert(text_parts, "━━━ " .. character.name .. " ━━━\n\n")

    -- Rating
    table.insert(text_parts, "  " .. _("Rating") .. ":  " .. starsString(character.rating) .. "\n")

    -- Role
    table.insert(text_parts, "  " .. _("Role") .. ":    " .. getRoleLabel(character.role) .. "\n")

    -- Aliases
    if character.aliases and #character.aliases > 0 then
        table.insert(text_parts, "  " .. _("Aliases") .. ": " .. table.concat(character.aliases, ", ") .. "\n")
    end

    -- Relationships
    local outgoing = character.relationships or {}
    local incoming = self:getIncomingRelationships(character)
    local has_rels = #outgoing > 0 or #incoming > 0

    if has_rels then
        table.insert(text_parts, "\n" .. sep .. "\n")
        table.insert(text_parts, "  " .. _("Relationships") .. "\n")
        table.insert(text_parts, sep .. "\n")
        for _i, rel in ipairs(outgoing) do
            local label = getRelationshipLabel(rel.type)
            table.insert(text_parts, "  → " .. rel.target .. " (" .. label .. ")\n")
        end
        for _i, rel in ipairs(incoming) do
            local label = getRelationshipLabel(rel.type)
            table.insert(text_parts, "  ← " .. rel.source .. " (" .. label .. ")\n")
        end
    end

    -- Notes (general, not linked to pages)
    if character.notes and #character.notes > 0 then
        table.insert(text_parts, "\n" .. sep .. "\n")
        table.insert(text_parts, "  " .. _("Notes") .. " (" .. #character.notes .. ")\n")
        table.insert(text_parts, sep .. "\n")
        for _i, note in ipairs(character.notes) do
            table.insert(text_parts, "  ◆ " .. getNoteText(note) .. "\n\n")
        end
    else
        table.insert(text_parts, "\n  " .. _("No notes yet.") .. "\n")
    end

    local full_text = table.concat(text_parts)

    local viewer
    viewer = TextViewer:new{
        title = character.name,
        text = full_text,
        width = math.floor(Device.screen:getWidth() * 0.9),
        height = math.floor(Device.screen:getHeight() * 0.85),
        buttons_table = {
            {
                {
                    text = "★ " .. _("Rate"),
                    callback = function()
                        UIManager:close(viewer)
                        self:showRatingDialog(character, function()
                            self:showCharacterDetail(character)
                        end)
                    end,
                },
                {
                    text = _("Role"),
                    callback = function()
                        UIManager:close(viewer)
                        self:showRoleDialog(character, function()
                            self:showCharacterDetail(character)
                        end)
                    end,
                },
                {
                    text = _("Notes"),
                    callback = function()
                        UIManager:close(viewer)
                        self:showNotesManager(character)
                    end,
                },
            },
            {
                {
                    text = _("Aliases"),
                    callback = function()
                        UIManager:close(viewer)
                        self:showAliasManager(character)
                    end,
                },
                {
                    text = _("Relations"),
                    callback = function()
                        UIManager:close(viewer)
                        self:showRelationshipManager(character)
                    end,
                },
            },
            {
                {
                    text = _("Rename"),
                    callback = function()
                        UIManager:close(viewer)
                        self:showRenameDialog(character, function()
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

    local item_table = self.character_list_cache
    if not item_table then
        item_table = {}
        for _i, char in ipairs(self.characters) do
            local badges = {}
        -- Stars
            local rating = char.rating or 0
            if rating > 0 then
                table.insert(badges, ("★"):rep(rating))
            end
        -- Role
            local role = char.role or ""
            if role ~= "" then
                table.insert(badges, getRoleLabel(role))
            end
        -- Aliases
            if char.aliases and #char.aliases > 0 then
                table.insert(badges, T(_("%1 aliases"), #char.aliases))
            end
        -- Relationships
            local rel_count = (char.relationships and #char.relationships or 0)
                            + #self:getIncomingRelationships(char)
            if rel_count > 0 then
                table.insert(badges, T(_("%1 relations"), rel_count))
            end
        -- Counts
            if char.notes and #char.notes > 0 then
                table.insert(badges, T(_("%1 notes"), #char.notes))
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

            table.insert(item_table, {
                text = display_name .. info,
                character = char,
                callback = function()
                    self:showCharacterDetail(char)
                end,
            })
        end
        self.character_list_cache = item_table
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
        local buttons = {}
        for _i, s in ipairs(available) do
            table.insert(buttons, {
                {
                    text = s.name .. " (" .. s.count .. " chars)",
                    callback = function()
                        UIManager:close(self._series_picker)
                        self._series_picker = nil
                        self:linkToSeries(s.name)
                    end,
                },
                {
                    text = _("X"),
                    callback = function()
                        UIManager:close(self._series_picker)
                        self._series_picker = nil
                        self:confirmDeleteSeries(s)
                    end,
                },
            })
        end
        table.insert(buttons, {
            {
                text = _("＋ New series"),
                callback = function()
                    UIManager:close(self._series_picker)
                    self._series_picker = nil
                    self:showNewSeriesDialog()
                end,
            },
        })
        table.insert(buttons, {
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(self._series_picker)
                    self._series_picker = nil
                end,
            },
        })
        self._series_picker = ButtonDialog:new{
            title = _("Link book to series"),
            buttons = buttons,
        }
        UIManager:show(self._series_picker)
    else
        -- No existing series, go straight to create
        self:showNewSeriesDialog()
    end
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
    local old_characters = self.characters
    local had_characters = #old_characters > 0

    -- Switch to series storage
    self:setSeriesName(series_name)
    self:loadData()

    local series_had_characters = #self.characters > 0

    if had_characters then
        -- Merge old book characters into series
        local merged = self:mergeCharacters(old_characters)
        self:saveData()

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
        text = T(_("Unlink this book from series '%1'?\n\nThe shared series characters will remain in the series. This book will start with an empty character list."), series),
        ok_text = _("Unlink"),
        ok_callback = function()
            self:setSeriesName(nil)
            self.characters = {}
            self.characters_sorted = false
            self:saveData()
            UIManager:show(InfoMessage:new{
                text = T(_("Unlinked from series '%1'."), series),
                timeout = 2,
            })
        end,
    })
end

--- List all available series files
function CharacterTracker:getAvailableSeries()
    local series = {}
    local dir = self:getSeriesDir()
    for entry in lfs.dir(dir) do
        if entry:match("%.json$") then
            local name = entry:gsub("%.json$", ""):gsub("_", " ")
            local path = dir .. "/" .. entry
            local chars = self:loadCharactersFromFile(path)
            table.insert(series, {
                name = name,
                path = path,
                count = #chars,
            })
        end
    end
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

function CharacterTracker:confirmDeleteSeries(s)
    UIManager:show(ConfirmBox:new{
        text = T(_("Delete series '%1'?\n\nThis will permanently remove the shared character file (%2 characters). Books currently linked to this series will lose access to its characters."), s.name, s.count),
        ok_text = _("Delete"),
        ok_callback = function()
            os.remove(s.path)
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
