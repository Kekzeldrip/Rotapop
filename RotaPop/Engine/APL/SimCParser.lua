-- SimCParser.lua
-- Parses SimulationCraft action priority list text into Rotapop APL entries.
--
-- Supported input formats:
--   actions=spell_name
--   actions+=/spell_name,if=condition
--   actions.listname=spell_name,if=condition
--   actions.listname+=/spell_name
--
-- Supported condition tokens:
--   buff.X.up / buff.X.down / buff.X.remains / buff.X.stack
--   debuff.X.up / debuff.X.down / debuff.X.remains
--   cooldown.X.ready / cooldown.X.remains
--   talent.X.enabled
--   active_enemies>N
--   maelstrom_weapon.stack>=N (Enhancement shorthand)
--   variable.X (treated as true)
--   Logical operators: & (and), | (or), ! (not)
--   Comparison operators: >=, <=, >, <, =, !=
--   Numeric literals and parenthesized groups
--
-- Usage:
--   /rotapop simc <paste your SimC profile>
--   Rotapop.SimCParser:Parse(text) → { list_name = { {spellID, condFn}, ... } }

Rotapop = Rotapop or {}
Rotapop.SimCParser = {}

local Parser = Rotapop.SimCParser
local SE     = Rotapop.SimEngine
local SC     = Rotapop.StateCache

-- ============================================================
-- Spell name → spellID mapping
-- Covers Enhancement Shaman + common racials.
-- Extensible: call Parser:RegisterSpell(name, spellID) to add more.
-- ============================================================
local spellMap = {
    -- Enhancement Shaman
    ["windfury_weapon"]     = 33757,
    ["flametongue_weapon"]  = 318038,
    ["lightning_shield"]    = 192106,
    ["stormstrike"]         = 17364,
    ["windstrike"]          = 115356,
    ["lava_lash"]           = 60103,
    ["crash_lightning"]     = 187874,
    ["flame_shock"]         = 188389,
    ["lightning_bolt"]      = 188196,
    ["chain_lightning"]     = 188443,
    ["tempest"]             = 452201,
    ["primordial_storm"]    = 375986,
    ["ascendance"]          = 114051,
    ["doom_winds"]          = 384352,
    ["sundering"]           = 197214,
    ["surging_totem"]       = 444995,
    ["voltaic_blaze"]       = 468283,
    ["feral_spirit"]        = 51533,

    -- Common racials
    ["blood_fury"]          = 20572,
    ["berserking"]          = 26297,
    ["fireblood"]           = 265221,
    ["ancestral_call"]      = 274738,

    -- Fury Warrior (example)
    ["recklessness"]        = 1719,
    ["rampage"]             = 184367,
    ["bloodthirst"]         = 23881,
    ["whirlwind"]           = 190411,

    -- Common utility
    ["auto_attack"]         = nil,  -- ignored
    ["use_items"]           = nil,  -- ignored
    ["potion"]              = nil,  -- ignored
    ["snapshot_stats"]      = nil,  -- ignored
}

-- Buff name → buff spellID mapping
local buffMap = {
    ["ascendance"]          = 114051,
    ["doom_winds"]          = 384352,
    ["maelstrom_weapon"]    = 344179,
    ["crash_lightning"]     = 333964,
    ["whirling_air"]        = 455090,
    ["whirling_fire"]       = 455089,
    ["whirling_earth"]      = 455091,
    ["hot_hand"]            = 215785,
    ["converging_storms"]   = 198300,
    ["primordial_storm"]    = 375986,
}

-- Debuff name → debuff spellID mapping
local debuffMap = {
    ["flame_shock"]         = 188389,
    ["lashing_flames"]      = 334168,
}

-- Talent name → talent spellID mapping
local talentMap = {
    ["thorims_invocation"]  = 384444,
    ["storm_unleashed"]     = 390352,
    ["splitstream"]         = 382033,
    ["fire_nova"]           = 333974,
    ["feral_spirit"]        = 51533,
    ["surging_elements"]    = 455100,
    ["elemental_tempo"]     = 383389,
    ["ascendance"]          = 114051,
    ["doom_winds"]          = 384352,
    ["surging_totem"]       = 444995,
}

--- Register additional spell name → ID mappings.
-- @param name    string  SimC spell name (lowercase, underscored)
-- @param spellID number
function Parser:RegisterSpell(name, spellID)
    spellMap[name:lower()] = spellID
end

--- Register additional buff name → ID mappings.
function Parser:RegisterBuff(name, buffID)
    buffMap[name:lower()] = buffID
end

--- Register additional debuff name → ID mappings.
function Parser:RegisterDebuff(name, debuffID)
    debuffMap[name:lower()] = debuffID
end

--- Register additional talent name → ID mappings.
function Parser:RegisterTalent(name, talentID)
    talentMap[name:lower()] = talentID
end

-- ============================================================
-- Condition compiler — converts SimC condition strings to Lua functions
-- ============================================================

--- Safe aura lookup
local function getAuraData(unit, spellID, filter)
    local ok, result = pcall(C_UnitAuras.GetAuraDataBySpellID, unit, spellID, filter)
    if ok then return result end
    return nil
end

--- Compile a SimC condition string into a Lua function.
-- Returns function() → bool, or nil if condition is empty/unparseable.
-- @param condStr string  e.g. "buff.ascendance.up&cooldown.doom_winds.remains<5"
-- @return function|nil
function Parser:CompileCondition(condStr)
    if not condStr or condStr == "" then return nil end

    -- Build a Lua expression string from the SimC condition
    local expr = condStr

    -- Replace SimC logical operators with Lua equivalents
    -- Must handle & and | carefully (not && / ||)
    -- Process from innermost constructs outward

    -- buff.X.up → hasBuff check
    expr = expr:gsub("buff%.([%w_]+)%.up", function(name)
        local id = buffMap[name]
        if not id then return "false" end
        return string.format("(getAuraData('player',%d,'HELPFUL')~=nil)", id)
    end)

    -- buff.X.down → not hasBuff
    expr = expr:gsub("buff%.([%w_]+)%.down", function(name)
        local id = buffMap[name]
        if not id then return "true" end
        return string.format("(getAuraData('player',%d,'HELPFUL')==nil)", id)
    end)

    -- buff.X.remains (comparison follows)
    expr = expr:gsub("buff%.([%w_]+)%.remains", function(name)
        local id = buffMap[name]
        if not id then return "0" end
        return string.format("getBuffRemains(%d)", id)
    end)

    -- buff.X.stack
    expr = expr:gsub("buff%.([%w_]+)%.stack", function(name)
        local id = buffMap[name]
        if not id then return "0" end
        return string.format("getBuffStacks(%d)", id)
    end)

    -- debuff.X.up
    expr = expr:gsub("debuff%.([%w_]+)%.up", function(name)
        local id = debuffMap[name]
        if not id then return "false" end
        return string.format("(getAuraData('target',%d,'HARMFUL')~=nil)", id)
    end)

    -- debuff.X.down
    expr = expr:gsub("debuff%.([%w_]+)%.down", function(name)
        local id = debuffMap[name]
        if not id then return "true" end
        return string.format("(getAuraData('target',%d,'HARMFUL')==nil)", id)
    end)

    -- debuff.X.remains / dot.X.remains
    expr = expr:gsub("[de][eo][bt]u?f?f?%.([%w_]+)%.remains", function(name)
        local id = debuffMap[name]
        if not id then return "0" end
        return string.format("getDebuffRemains(%d)", id)
    end)

    -- cooldown.X.ready
    expr = expr:gsub("cooldown%.([%w_]+)%.ready", function(name)
        local id = spellMap[name]
        if not id then return "true" end
        return string.format("(getCDRemains(%d)==0)", id)
    end)

    -- cooldown.X.remains
    expr = expr:gsub("cooldown%.([%w_]+)%.remains", function(name)
        local id = spellMap[name]
        if not id then return "0" end
        return string.format("getCDRemains(%d)", id)
    end)

    -- talent.X.enabled
    expr = expr:gsub("talent%.([%w_]+)%.enabled", function(name)
        local id = talentMap[name]
        if not id then return "false" end
        return string.format("hasTalent(%d)", id)
    end)

    -- active_enemies (literal number comparison follows)
    expr = expr:gsub("active_enemies", "getActiveEnemies()")

    -- maelstrom_weapon.stack (Enhancement shorthand)
    expr = expr:gsub("maelstrom_weapon%.stack", "getBuffStacks(344179)")

    -- pet.surging_totem.active
    expr = expr:gsub("pet%.surging_totem%.active", "isSurgingTotemActive()")

    -- pet.searing_totem.active
    expr = expr:gsub("pet%.searing_totem%.active", "isSearingTotemActive()")

    -- time (combat time)
    expr = expr:gsub("([^%w_])time([^%w_])", "%1getCombatTime()%2")
    expr = expr:gsub("^time([^%w_])", "getCombatTime()%1")

    -- SimC logical operators → Lua
    expr = expr:gsub("&", " and ")
    expr = expr:gsub("|", " or ")
    expr = expr:gsub("!", " not ")

    -- SimC = (single equals for comparison) → Lua ==
    -- But only when not already == or !=
    expr = expr:gsub("([^!=<>])=([^=])", "%1==%2")

    -- SimC != → Lua ~=
    expr = expr:gsub("!=", "~=")

    -- Build the function with helper locals in scope
    local funcStr = string.format([[
        local getAuraData      = ...
        local GetTime          = GetTime
        local C_Spell          = C_Spell
        local IsSpellKnown     = IsSpellKnown
        local GetTotemInfo     = GetTotemInfo
        local UnitExists       = UnitExists
        local UnitCanAttack    = UnitCanAttack
        local math             = math

        local function getBuffRemains(id)
            local d = getAuraData("player", id, "HELPFUL")
            if not d then return 0 end
            if not d.expirationTime or d.expirationTime == 0 then return math.huge end
            return math.max(0, d.expirationTime - GetTime())
        end
        local function getDebuffRemains(id)
            local d = getAuraData("target", id, "HARMFUL")
            if not d then return 0 end
            if not d.expirationTime or d.expirationTime == 0 then return math.huge end
            return math.max(0, d.expirationTime - GetTime())
        end
        local function getBuffStacks(id)
            local d = getAuraData("player", id, "HELPFUL")
            return d and (d.applications or 0) or 0
        end
        local function getCDRemains(spellID)
            local cd = C_Spell.GetSpellCooldown(spellID)
            if not cd or not cd.startTime or cd.startTime == 0 then return 0 end
            if not cd.duration or cd.duration == 0 then return 0 end
            return math.max(0, (cd.startTime + cd.duration) - GetTime())
        end
        local function hasTalent(spellID)
            local ok, result = pcall(IsSpellKnown, spellID)
            return ok and result or false
        end
        local function getActiveEnemies()
            local count = 0
            for i = 1, 40 do
                local unit = "nameplate" .. i
                if UnitExists(unit) and UnitCanAttack("player", unit) then
                    count = count + 1
                end
            end
            return math.max(1, count)
        end
        local function isSurgingTotemActive()
            local ok, haveTotem, _, startTime, duration = pcall(GetTotemInfo, 2)
            if not ok or not haveTotem then return false end
            return startTime ~= nil and duration ~= nil
                and (startTime + duration) > GetTime()
        end
        local function isSearingTotemActive()
            local ok, haveTotem, _, startTime, duration = pcall(GetTotemInfo, 1)
            if not ok or not haveTotem then return false end
            return startTime ~= nil and duration ~= nil
                and (startTime + duration) > GetTime()
        end
        local function getCombatTime()
            return Rotapop.getCombatTime and Rotapop.getCombatTime() or 0
        end

        return function() return (%s) end
    ]], expr)

    local compiled, err = loadstring(funcStr)
    if not compiled then
        if ROTAPOP_DEBUG then
            print("|cffff0000Rotapop SimCParser|r condition compile error: "
                .. tostring(err) .. " | expr: " .. expr)
        end
        return nil
    end

    local ok, condFn = pcall(compiled, getAuraData)
    if not ok or type(condFn) ~= "function" then
        if ROTAPOP_DEBUG then
            print("|cffff0000Rotapop SimCParser|r condition runtime error: "
                .. tostring(condFn))
        end
        return nil
    end

    return condFn
end

-- ============================================================
-- Text parser — converts SimC text into structured APL tables
-- ============================================================

--- Parse a SimC action list text block.
-- @param text string  Full SimC APL text (multi-line)
-- @return table  { default = { {spellID, condFn}, ... }, listname = { ... }, ... }
function Parser:Parse(text)
    if not text or text == "" then return {} end

    local lists = {}
    local skipped = 0

    for line in text:gmatch("[^\r\n]+") do
        -- Trim whitespace
        line = line:match("^%s*(.-)%s*$")

        -- Skip comments and empty lines
        if line ~= "" and line:sub(1, 1) ~= "#" then
            -- Match: actions.listname+=/spell,params  OR  actions+=/spell,params
            local listName, spellAndParams = line:match("^actions%.([%w_]+)%+?=/?(.+)$")
            if not listName then
                spellAndParams = line:match("^actions%+?=/?(.+)$")
                listName = "default"
            end

            if spellAndParams then
                -- Extract spell name (everything before first comma)
                local spellName, paramStr = spellAndParams:match("^([%w_]+),?(.*)$")
                if spellName then
                    spellName = spellName:lower()
                    local spellID = spellMap[spellName]

                    if spellID then
                        -- Extract if= condition
                        local condStr = paramStr and paramStr:match("if=([^,]+)")
                        local condFn = self:CompileCondition(condStr)

                        -- Track spell in StateCache
                        SC:Track(spellID)

                        if not lists[listName] then
                            lists[listName] = {}
                        end
                        table.insert(lists[listName], { spellID, condFn })
                    elseif spellName == "call_action_list" then
                        -- call_action_list,name=X → resolved later
                        local subName = paramStr and paramStr:match("name=([%w_]+)")
                        if subName then
                            if not lists[listName] then
                                lists[listName] = {}
                            end
                            table.insert(lists[listName], {
                                _call_list = subName,
                                _condition = paramStr and paramStr:match("if=([^,]+)"),
                            })
                        end
                    elseif spellMap[spellName] == nil and spellName ~= "run_action_list"
                        and spellName ~= "variable" and spellName ~= "invoke_external_buff"
                    then
                        skipped = skipped + 1
                        if ROTAPOP_DEBUG then
                            print("|cffffcc00Rotapop SimCParser|r skipped unknown: "
                                .. spellName)
                        end
                    end
                end
            end
        end
    end

    -- Resolve call_action_list references
    for listName, entries in pairs(lists) do
        for i, entry in ipairs(entries) do
            if entry._call_list then
                local target = lists[entry._call_list]
                if target then
                    local condFn = self:CompileCondition(entry._condition)
                    -- Replace with sublist entry compatible with evalList
                    entries[i] = { sublist = target, condition = condFn }
                else
                    -- Remove unresolved reference
                    entries[i] = nil
                end
            end
        end
        -- Compact nils
        local compacted = {}
        for _, v in ipairs(entries) do
            if v then compacted[#compacted + 1] = v end
        end
        lists[listName] = compacted
    end

    if ROTAPOP_DEBUG then
        local total = 0
        for _, entries in pairs(lists) do
            total = total + #entries
        end
        print(string.format(
            "|cff00ff00Rotapop SimCParser|r parsed %d actions (%d skipped) in %d lists",
            total, skipped, (function()
                local n = 0
                for _ in pairs(lists) do n = n + 1 end
                return n
            end)()
        ))
    end

    return lists
end

--- Parse and install a SimC APL text as the active rotation.
-- Replaces the current APL in SimEngine with the parsed one.
-- Falls back to the "default" list as the main entry point.
-- @param text string  Full SimC APL text
-- @return bool  true if at least one action was parsed
function Parser:ImportAndActivate(text)
    local lists = self:Parse(text)

    local defaultList = lists["default"]
    if not defaultList or #defaultList == 0 then
        print("|cffff0000Rotapop|r SimC import failed: no actions found in default list.")
        return false
    end

    -- Install as the active APL by overriding GetNextSpell
    SE:GetNextSpell_Install(lists)

    local count = 0
    for _, entries in pairs(lists) do
        count = count + #entries
    end
    print(string.format(
        "|cff00ff00Rotapop|r SimC APL imported: %d actions loaded.", count
    ))
    return true
end

-- ============================================================
-- SimEngine extension: install parsed APL lists
-- ============================================================

--- Installs parsed SimC APL lists as the active rotation.
-- Overrides GetNextSpell with a version that evaluates the parsed lists.
-- @param lists table  Output from Parser:Parse()
function SE:GetNextSpell_Install(lists)
    local defaultList = lists["default"]

    -- evalList compatible with the ShamanEnhancement format
    local function evalParsedList(list, unitState)
        -- Pass 1: ready + condition
        for _, entry in ipairs(list) do
            if entry.sublist then
                local condMet = true
                if entry.condition then
                    local ok, result = pcall(entry.condition)
                    condMet = ok and (result == true)
                end
                if condMet then
                    local result, ready = evalParsedList(entry.sublist, unitState)
                    if result and ready then return result, true end
                end
            else
                local spellID   = entry[1]
                local condition = entry[2]

                if spellID then
                    local ready = Rotapop.CooldownAdapter:IsReady(spellID)
                    if ready then
                        local condMet = true
                        if condition then
                            local ok, result = pcall(condition)
                            condMet = ok and (result == true)
                        end
                        if condMet then
                            return spellID, true
                        end
                    end
                end
            end
        end

        -- Pass 2: fallback (condition only, ignore CD)
        for _, entry in ipairs(list) do
            if not entry.sublist then
                local spellID   = entry[1]
                local condition = entry[2]
                if spellID then
                    local spellInfo = C_Spell.GetSpellInfo(spellID)
                    if spellInfo then
                        local condMet = true
                        if condition then
                            local ok, result = pcall(condition)
                            condMet = ok and (result == true)
                        end
                        if condMet then
                            return spellID, false
                        end
                    end
                end
            end
        end

        -- Pass 3: any known spell
        for _, entry in ipairs(list) do
            if not entry.sublist and entry[1] then
                local spellInfo = C_Spell.GetSpellInfo(entry[1])
                if spellInfo then
                    return entry[1], false
                end
            end
        end

        return nil, false
    end

    -- Override GetNextSpell
    function SE:GetNextSpell(unitState)
        return evalParsedList(defaultList, unitState)
    end
end

--- Returns the current spell name → ID mapping table (read-only copy).
function Parser:GetSpellMap()
    local copy = {}
    for k, v in pairs(spellMap) do
        copy[k] = v
    end
    return copy
end
