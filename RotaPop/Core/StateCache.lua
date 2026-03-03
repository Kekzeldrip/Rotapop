-- StateCache.lua
-- Event-driven Cache über CooldownAdapter.
-- Events:
--   SPELL_UPDATE_COOLDOWN → https://warcraft.wiki.gg/wiki/SPELL_UPDATE_COOLDOWN
--   SPELL_UPDATE_CHARGES  → https://warcraft.wiki.gg/wiki/SPELL_UPDATE_CHARGES

Rotapop = Rotapop or {}
Rotapop.StateCache = {}

local SC = Rotapop.StateCache
-- NOTE: CooldownAdapter and EventBus references are resolved at call time
-- (not at load time) to tolerate any load-order variation.
local EB = Rotapop.EventBus

local cache = {}

SC.trackedSpells = {}

--- Registriere eine SpellID für Tracking.
function SC:Track(spellID)
    self.trackedSpells[spellID] = true
end

local function refreshSpell(spellID)
    if SC.trackedSpells[spellID] then
        cache[spellID] = Rotapop.CooldownAdapter:GetSpellState(spellID)
    end
end

local function refreshAll()
    for spellID in pairs(SC.trackedSpells) do
        cache[spellID] = Rotapop.CooldownAdapter:GetSpellState(spellID)
    end
end

--- Gibt den gecachten State zurück.
-- @param spellID number
-- @return table|nil
function SC:GetState(spellID)
    if not cache[spellID] then
        cache[spellID] = Rotapop.CooldownAdapter:GetSpellState(spellID)
    end
    return cache[spellID]
end

--- Kompletten Cache leeren.
function SC:InvalidateAll()
    cache = {}
end

-- SPELL_UPDATE_COOLDOWN → targeted invalidation using event parameters.
-- https://warcraft.wiki.gg/wiki/SPELL_UPDATE_COOLDOWN
-- Parameters (11.1.5+/12.x): spellID, baseSpellID, category, startRecoveryCategory
EB:Subscribe("SPELL_UPDATE_COOLDOWN", function(_, spellID, baseSpellID)
    if spellID then
        -- Targeted: refresh the specific spell and its base spell.
        refreshSpell(spellID)
        if baseSpellID and baseSpellID ~= spellID then
            refreshSpell(baseSpellID)
        end
        -- Also refresh all spells that share the same CooldownViewer entry
        -- (linked spells whose cooldowns change together).
        for _, linkedID in ipairs(Rotapop.CooldownAdapter:GetLinkedSpells(spellID)) do
            refreshSpell(linkedID)
        end
    else
        -- No spellID: full refresh (fired on login / spec-change / etc.)
        refreshAll()
    end
end)

-- SPELL_UPDATE_CHARGES → betroffenen Spell aktualisieren
-- https://warcraft.wiki.gg/wiki/SPELL_UPDATE_CHARGES
EB:Subscribe("SPELL_UPDATE_CHARGES", function(_, spellID)
    if spellID then
        refreshSpell(spellID)
    else
        refreshAll()
    end
end)

-- Cast-Events → vollständiger Refresh
EB:Subscribe("UNIT_SPELLCAST_START", function(_, unit)
    if unit == "player" then refreshAll() end
end)

EB:Subscribe("UNIT_SPELLCAST_SUCCEEDED", function(_, unit)
    if unit == "player" then
        C_Timer.After(0.05, function()
            Rotapop.CooldownAdapter:RebuildLookup()
            refreshAll()
        end)
    end
end)

-- Ressource-Changes können Usability ändern
EB:Subscribe("UNIT_POWER_UPDATE", function(_, unit)
    if unit == "player" then refreshAll() end
end)