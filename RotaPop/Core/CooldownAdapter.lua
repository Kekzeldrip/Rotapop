-- CooldownAdapter.lua
-- Normalizes spell cooldown state using C_Spell.* APIs as primary source.
--
-- Fallback Design:
--   1. C_Spell.GetSpellCooldown  — primary cooldown source
--      https://warcraft.wiki.gg/wiki/API_C_Spell.GetSpellCooldown
--   2. C_Spell.GetSpellCharges   — charge information
--      https://warcraft.wiki.gg/wiki/API_C_Spell.GetSpellCharges
--   3. C_Spell.IsSpellUsable     — usability check
--      https://warcraft.wiki.gg/wiki/API_C_Spell.IsSpellUsable
--   4. C_CooldownViewer.*        — optional enrichment (linked spells)
--      https://warcraft.wiki.gg/wiki/API_C_CooldownViewer.GetCooldownViewerCooldownInfo
--      Only used when the namespace is available and verified.
--      (Verification is a separate step, not part of this implementation.)
--
-- No-Legacy Policy: no dependency on removed global functions such as the
-- old GetSpellCooldown.  All calls go through C_* namespaces.

Rotapop = Rotapop or {}
Rotapop.CooldownAdapter = {}

local CA = Rotapop.CooldownAdapter

-- ============================================================
-- Optional: C_CooldownViewer lookup (enrichment only)
-- ============================================================

-- Guard: C_CooldownViewer may not be available in every context.
local hasCooldownViewer = (
    type(C_CooldownViewer) == "table"
    and type(C_CooldownViewer.GetCooldownViewerCategorySet) == "function"
    and type(C_CooldownViewer.GetCooldownViewerCooldownInfo) == "function"
)

-- Lookup-Tabelle: spellID → cooldownID (populated only when C_CooldownViewer is present)
local spellToCooldownID = {}

-- Maximale Kategorie-ID die wir scannen
local MAX_CATEGORY = 20

--- Baut die Lookup-Tabelle spellID → cooldownID auf.
-- https://warcraft.wiki.gg/wiki/Category:API_C_CooldownViewer
local function buildLookupTable()
    spellToCooldownID = {}
    if not hasCooldownViewer then return end

    for category = 1, MAX_CATEGORY do
        local ok, set = pcall(
            C_CooldownViewer.GetCooldownViewerCategorySet, category, true
        )
        if ok and set then
            for _, cooldownID in pairs(set) do
                local ok2, info = pcall(
                    C_CooldownViewer.GetCooldownViewerCooldownInfo, cooldownID
                )
                if ok2 and info and info.spellID then
                    spellToCooldownID[info.spellID] = cooldownID

                    if info.overrideSpellID
                        and info.overrideSpellID ~= info.spellID
                    then
                        spellToCooldownID[info.overrideSpellID] = cooldownID
                    end

                    if info.linkedSpellIDs then
                        for _, linkedID in pairs(info.linkedSpellIDs) do
                            if linkedID and linkedID ~= 0 then
                                spellToCooldownID[linkedID] = cooldownID
                            end
                        end
                    end
                end
            end
        end
    end
end

--- Gibt den rohen CooldownViewer-Info für eine SpellID zurück (optional enrichment).
-- @return table|nil  CooldownViewerCooldownInfo or nil
local function getRawCooldownViewerInfo(spellID)
    if not hasCooldownViewer then return nil end
    local cooldownID = spellToCooldownID[spellID]
    if not cooldownID then return nil end
    local ok, info = pcall(
        C_CooldownViewer.GetCooldownViewerCooldownInfo, cooldownID
    )
    if ok then return info end
    return nil
end

-- ============================================================
-- Öffentliche API
-- ============================================================

--- Gibt den normalisierten Spell-State zurück.
-- Return format (see issue spec):
-- {
--   isKnown      = bool,
--   isUsable     = bool,
--   charges      = { cur, max, start, duration },
--   cooldown     = { start, duration, isEnabled, modRate, isOnGCDMaybe },
--   linkedSpells = { ... },
-- }
-- @param spellID number
-- @return table|nil
function CA:GetSpellState(spellID)
    -- C_Spell.GetSpellInfo → https://warcraft.wiki.gg/wiki/API_C_Spell.GetSpellInfo
    local spellInfo = C_Spell.GetSpellInfo(spellID)
    if not spellInfo then return nil end

    -- C_Spell.IsSpellUsable → https://warcraft.wiki.gg/wiki/API_C_Spell.IsSpellUsable
    local isUsable, _ = C_Spell.IsSpellUsable(spellID)

    -- Charges
    -- C_Spell.GetSpellCharges → https://warcraft.wiki.gg/wiki/API_C_Spell.GetSpellCharges
    local chargesInfo = C_Spell.GetSpellCharges(spellID)
    local charges
    if chargesInfo then
        charges = {
            cur      = chargesInfo.currentCharges,
            max      = chargesInfo.maxCharges,
            start    = chargesInfo.cooldownStartTime,
            duration = chargesInfo.cooldownDuration,
        }
    else
        charges = { cur = 1, max = 1, start = nil, duration = nil }
    end

    -- Cooldown (primary: C_Spell.GetSpellCooldown)
    -- https://warcraft.wiki.gg/wiki/API_C_Spell.GetSpellCooldown
    -- Returns SpellCooldownInfo → https://warcraft.wiki.gg/wiki/Struct_SpellCooldownInfo
    local cd = C_Spell.GetSpellCooldown(spellID)
    local cooldown = {
        start        = cd and cd.startTime or nil,
        duration     = cd and cd.duration  or nil,
        isEnabled    = cd and cd.isEnabled or nil,
        modRate      = cd and cd.modRate   or nil,
        -- [context sensitive] isOnGCDMaybe is a heuristic; reliable use
        -- typically in conjunction with SPELL_UPDATE_COOLDOWN.
        isOnGCDMaybe = (
            cd
            and cd.startTime
            and cd.startTime > 0
            and cd.duration
            and cd.duration <= 1.5
        ) or false,
    }

    -- Linked spells (optional enrichment from C_CooldownViewer)
    -- https://warcraft.wiki.gg/wiki/API_C_CooldownViewer.GetCooldownViewerCooldownInfo
    local linkedSpells = {}
    local cvInfo = getRawCooldownViewerInfo(spellID)
    if cvInfo and cvInfo.linkedSpellIDs then
        for _, linkedID in pairs(cvInfo.linkedSpellIDs) do
            if linkedID and linkedID ~= 0 then
                linkedSpells[#linkedSpells + 1] = linkedID
            end
        end
    end

    return {
        isKnown      = true,
        isUsable     = isUsable or false,
        charges      = charges,
        cooldown     = cooldown,
        linkedSpells = linkedSpells,
    }
end

--- Ist der Spell gerade castbar?
-- @param spellID number
-- @return bool
function CA:IsReady(spellID)
    local now = GetTime()

    -- 0. Ist der Spell überhaupt castbar?
    -- C_Spell.IsSpellUsable → https://warcraft.wiki.gg/wiki/API_C_Spell.IsSpellUsable
    local isUsable, _ = C_Spell.IsSpellUsable(spellID)
    if not isUsable then return false end

    -- 1. Charges haben Vorrang
    -- C_Spell.GetSpellCharges → https://warcraft.wiki.gg/wiki/API_C_Spell.GetSpellCharges
    local chargesInfo = C_Spell.GetSpellCharges(spellID)
    if chargesInfo then
        return chargesInfo.currentCharges >= 1
    end

    -- 2. C_Spell.GetSpellCooldown — primary CD source
    -- https://warcraft.wiki.gg/wiki/API_C_Spell.GetSpellCooldown
    local cd = C_Spell.GetSpellCooldown(spellID)
    if not cd then return false end
    if cd.isEnabled == false then return false end
    if not cd.startTime or cd.startTime == 0 then return true end
    if not cd.duration  or cd.duration  == 0 then return true end
    -- [context sensitive] GCD ignorieren
    if cd.duration <= 1.5 then return true end

    return (cd.startTime + cd.duration) <= now
end

--- Rebuild Lookup-Tabelle (C_CooldownViewer enrichment).
function CA:RebuildLookup()
    buildLookupTable()
end

--- Debug: Gibt alle bekannten spellID → cooldownID Mappings zurück.
function CA:GetLookupTable()
    return spellToCooldownID
end