-- AssistedCombatAdapter.lua
-- Fallback data source using WoW's built-in C_AssistedCombat API.
--
-- When the SimEngine APL evaluation cannot determine a next spell
-- (e.g. spec mismatch, missing mappings, or all conditions fail),
-- we ask Blizzard's assisted-combat system for a recommendation.
--
-- C_AssistedCombat is a client-side API — availability depends on
-- the WoW version and game settings.  All calls are pcall-guarded.

Rotapop = Rotapop or {}
Rotapop.AssistedCombat = {}

local AC = Rotapop.AssistedCombat

-- Guard: C_AssistedCombat may not exist on all clients.
local hasAPI = (
    type(C_AssistedCombat) == "table"
    and type(C_AssistedCombat.IsAvailable) == "function"
)

--- Is the C_AssistedCombat system available and enabled?
-- @return bool
function AC:IsAvailable()
    if not hasAPI then return false end
    local ok, available = pcall(C_AssistedCombat.IsAvailable)
    return ok and available or false
end

--- Returns the spell ID Blizzard recommends casting next, or nil.
-- @return number|nil
function AC:GetNextCastSpell()
    if not hasAPI then return nil end
    local ok, available = pcall(C_AssistedCombat.IsAvailable)
    if not (ok and available) then return nil end

    local castOk, spellID = pcall(C_AssistedCombat.GetNextCastSpell)
    if castOk and spellID and spellID ~= 0 then
        return spellID
    end
    return nil
end

--- Returns the full rotation spell list from C_AssistedCombat, or {}.
-- @return table  Array of spellIDs (may be empty)
function AC:GetRotationSpells()
    if not hasAPI then return {} end
    local ok, available = pcall(C_AssistedCombat.IsAvailable)
    if not (ok and available) then return {} end

    local rotOk, spells = pcall(C_AssistedCombat.GetRotationSpells)
    if rotOk and spells and type(spells) == "table" then
        return spells
    end
    return {}
end
