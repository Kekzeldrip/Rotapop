-- ShamanEnhancement.lua
-- Enhancement Shaman APL
-- Portiert von SimC: shaman_enhancement.simc (midnight branch)

local SE = Rotapop.SimEngine
local SC = Rotapop.StateCache

local SPELL = {
    WINDFURY_WEAPON     = 33757,
    FLAMETONGUE_WEAPON  = 318038,
    LIGHTNING_SHIELD    = 192106,
    STORMSTRIKE         = 17364,
    WINDSTRIKE          = 115356,
    LAVA_LASH           = 60103,
    CRASH_LIGHTNING     = 187874,
    FLAME_SHOCK         = 188389,
    LIGHTNING_BOLT      = 188196,
    CHAIN_LIGHTNING     = 188443,
    TEMPEST             = 452201,
    PRIMORDIAL_STORM    = 375986,
    ASCENDANCE          = 114051,
    DOOM_WINDS          = 384352,
    SUNDERING           = 197214,
    SURGING_TOTEM       = 444995,
    VOLTAIC_BLAZE       = 468283,
    BLOOD_FURY          = 20572,
    BERSERKING          = 26297,
    FIREBLOOD           = 265221,
    ANCESTRAL_CALL      = 274738,
}

-- Talent spell IDs — used with hasTalent() to check if a talent is learned.
-- These are DISTINCT from spell IDs used to cast abilities.
local TALENT = {
    THORIMS_INVOCATION = 384444,  -- Thorim's Invocation (hero talent)
    STORM_UNLEASHED    = 390352,  -- Storm Unleashed
    SPLITSTREAM        = 382033,  -- Splitstream (Lava Lash cleave talent)
    FIRE_NOVA          = 333974,  -- Fire Nova
    FERAL_SPIRIT       = 51533,   -- Feral Spirit (wolf summon)
    SURGING_ELEMENTS   = 455100,  -- Surging Elements (passive; NOT Surging Totem 444995)
    ELEMENTAL_TEMPO    = 383389,  -- Elemental Tempo (Maelstrom CD reduction)
}

local BUFF = {
    ASCENDANCE          = 114051,
    DOOM_WINDS          = 384352,
    MAELSTROM_WEAPON    = 344179,
    CRASH_LIGHTNING     = 333964,
    WHIRLING_AIR        = 455090,
    WHIRLING_FIRE       = 455089,
    WHIRLING_EARTH      = 455091,
    HOT_HAND            = 215785,
    CONVERGING_STORMS   = 198300,
    PRIMORDIAL_STORM    = 375986,
}

local DEBUFF = {
    FLAME_SHOCK         = 188389,
    LASHING_FLAMES      = 334168,
}

for _, id in pairs(SPELL) do
    SC:Track(id)
end

-- ============================================================
-- Hilfsfunktionen — robuste Version
-- ============================================================

--- Aura-Daten sicher abrufen.
-- Versucht C_UnitAuras.GetAuraDataBySpellID,
-- fällt zurück auf AuraUtil.FindAuraByName falls nötig.
-- @param unit    string
-- @param spellID number
-- @param filter  string "HELPFUL"|"HARMFUL"
-- @return table|nil  AuraData
local function getAuraData(unit, spellID, filter)
    -- C_UnitAuras.GetAuraDataBySpellID →
    -- https://warcraft.wiki.gg/wiki/API_C_UnitAuras.GetAuraDataBySpellID
    local ok, result = pcall(
        C_UnitAuras.GetAuraDataBySpellID, unit, spellID, filter
    )
    if ok then return result end
    return nil
end

--- Prüft ob ein Buff auf "player" aktiv ist.
local function hasBuff(buffID)
    return getAuraData("player", buffID, "HELPFUL") ~= nil
end

--- Prüft ob ein Debuff auf "target" aktiv ist.
local function targetHasDebuff(debuffID)
    return getAuraData("target", debuffID, "HARMFUL") ~= nil
end

--- Verbleibende Aura-Dauer in Sekunden.
-- @param spellID number
-- @param unit    string
-- @param filter  string
-- @return number  0 wenn nicht aktiv, math.huge wenn permanent
local function getAuraRemains(spellID, unit, filter)
    unit   = unit   or "player"
    filter = filter or "HELPFUL"
    local data = getAuraData(unit, spellID, filter)
    if not data then return 0 end
    if not data.expirationTime or data.expirationTime == 0 then
        return math.huge
    end
    return math.max(0, data.expirationTime - GetTime())
end

--- Maelstrom Weapon Stacks (Buff ID 344179).
local function getMaelstromStacks()
    local data = getAuraData("player", 344179, "HELPFUL")
    return data and (data.applications or 0) or 0
end

--- Verbleibende CD-Zeit in Sekunden.
local function getCDRemains(spellID)
    local cd = C_Spell.GetSpellCooldown(spellID)
    if not cd or not cd.startTime or cd.startTime == 0 then return 0 end
    if not cd.duration or cd.duration == 0 then return 0 end
    return math.max(0, (cd.startTime + cd.duration) - GetTime())
end

--- Charge-Bruchteil (z.B. 1.8 = fast 2 Charges).
local function getChargesFractional(spellID)
    local info = C_Spell.GetSpellCharges(spellID)
    if not info then return 1 end
    if info.currentCharges >= info.maxCharges then
        return info.maxCharges
    end
    if not info.cooldownStartTime or info.cooldownDuration == 0 then
        return info.currentCharges
    end
    local elapsed  = GetTime() - info.cooldownStartTime
    local fraction = math.min(1, elapsed / info.cooldownDuration)
    return info.currentCharges + fraction
end

--- Anzahl aktiver Feinde via Nameplates.
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

--- Talent aktiv via IsSpellKnown.
local function hasTalent(spellID)
    local ok, result = pcall(IsSpellKnown, spellID)
    return ok and result or false
end

--- Surging Totem pet aktiv (Earth totem slot).
-- Approximates pet.surging_totem.active for Totemic builds.
local function isSurgingTotemActive()
    local ok, haveTotem, _, startTime, duration = pcall(GetTotemInfo, 2)
    if not ok or not haveTotem then return false end
    return startTime ~= nil and duration ~= nil
        and (startTime + duration) > GetTime()
end

--- Searing Totem pet aktiv (Fire totem slot).
-- Approximates pet.searing_totem.active for AOE lava_lash check.
local function isSearingTotemActive()
    local ok, haveTotem, _, startTime, duration = pcall(GetTotemInfo, 1)
    if not ok or not haveTotem then return false end
    return startTime ~= nil and duration ~= nil
        and (startTime + duration) > GetTime()
end

-- ============================================================
-- evalList — wertet eine APL-Liste aus
-- Supports { sublist = list } entries for call_action_list.
-- Returns: spellID|nil, isReady (true = castable now)
-- Two-pass: first IsReady+condition, then condition-only fallback.
-- ============================================================
local function evalList(list, unitState)
    -- Pass 1: find a spell that is both ready and meets its condition
    for _, entry in ipairs(list) do
        if entry.sublist then
            local result, ready = evalList(entry.sublist, unitState)
            if result and ready then return result, true end
        else
            local spellID   = entry[1]
            local condition = entry[2]

            local readyOk, ready = pcall(
                Rotapop.CooldownAdapter.IsReady,
                Rotapop.CooldownAdapter, spellID
            )
            if readyOk and ready then
                local condMet = true
                if condition then
                    local ok, result = pcall(condition, unitState)
                    condMet = ok and (result == true)
                end
                if condMet then
                    return spellID, true
                end
            end
        end
    end

    -- Pass 2: fallback — find first known spell whose condition passes
    -- (even if on cooldown). Shows "what's coming next" instead of "?".
    for _, entry in ipairs(list) do
        if not entry.sublist then
            local spellID   = entry[1]
            local condition = entry[2]
            local infoOk, spellInfo = pcall(C_Spell.GetSpellInfo, spellID)
            if infoOk and spellInfo then
                local condMet = true
                if condition then
                    local ok, result = pcall(condition, unitState)
                    condMet = ok and (result == true)
                end
                if condMet then
                    return spellID, false
                end
            end
        end
    end

    -- Pass 3: last resort — any known spell from the list
    for _, entry in ipairs(list) do
        if not entry.sublist then
            local infoOk, spellInfo = pcall(C_Spell.GetSpellInfo, entry[1])
            if infoOk and spellInfo then
                return entry[1], false
            end
        end
    end

    return nil, false
end

-- ============================================================
-- APL Listen
-- ============================================================
local APL = {}

-- Shared buffs condition:
-- blood_fury/berserking/fireblood/ancestral_call,if=
--   (buff.ascendance.up | buff.doom_winds.up | pet.surging_totem.active |
--    (!talent.ascendance.enabled & !talent.doom_winds.enabled &
--     !talent.surging_totem.enabled))
local function buffsCondition()
    return hasBuff(BUFF.ASCENDANCE)
        or hasBuff(BUFF.DOOM_WINDS)
        or isSurgingTotemActive()
        or (not hasTalent(SPELL.ASCENDANCE)
            and not hasTalent(SPELL.DOOM_WINDS)
            and not hasTalent(SPELL.SURGING_TOTEM))
end

APL.buffs = {
    { SPELL.BLOOD_FURY,     buffsCondition },
    { SPELL.BERSERKING,     buffsCondition },
    { SPELL.FIREBLOOD,      buffsCondition },
    { SPELL.ANCESTRAL_CALL, buffsCondition },
}

APL.single_sb = {
    { SPELL.PRIMORDIAL_STORM, function()
        local mw = getMaelstromStacks()
        return mw >= 9
            or (getAuraRemains(BUFF.PRIMORDIAL_STORM, "player", "HELPFUL") <= 4
                and mw >= 5)
    end },
    -- voltaic_blaze,if=dot.flame_shock.remains=0&time<5
    { SPELL.VOLTAIC_BLAZE, function()
        return getAuraRemains(DEBUFF.FLAME_SHOCK, "target", "HARMFUL") == 0
            and Rotapop.getCombatTime() < 5
    end },
    -- lava_lash,if=!debuff.lashing_flames.up&time<5
    { SPELL.LAVA_LASH, function()
        return not targetHasDebuff(DEBUFF.LASHING_FLAMES)
            and Rotapop.getCombatTime() < 5
    end },
    -- call_action_list,name=buffs
    { sublist = APL.buffs },
    -- sundering,if=talent.surging_elements.enabled|talent.feral_spirit.enabled
    { SPELL.SUNDERING, function()
        return hasTalent(TALENT.SURGING_ELEMENTS) or hasTalent(TALENT.FERAL_SPIRIT)
    end },
    { SPELL.DOOM_WINDS, nil },
    -- crash_lightning,if=!buff.crash_lightning.up|talent.storm_unleashed.enabled
    { SPELL.CRASH_LIGHTNING, function()
        return not hasBuff(BUFF.CRASH_LIGHTNING) or hasTalent(TALENT.STORM_UNLEASHED)
    end },
    -- voltaic_blaze,if=(buff.doom_winds.up&buff.maelstrom_weapon.stack>=10-(1+2*talent.fire_nova.enabled)&!buff.maelstrom_weapon.stack=10)&talent.thorims_invocation.enabled
    { SPELL.VOLTAIC_BLAZE, function()
        local mw = getMaelstromStacks()
        local threshold = 10 - (1 + 2 * (hasTalent(TALENT.FIRE_NOVA) and 1 or 0))
        return hasBuff(BUFF.DOOM_WINDS)
            and mw >= threshold
            and mw ~= 10
            and hasTalent(TALENT.THORIMS_INVOCATION)
    end },
    -- windstrike,if=buff.maelstrom_weapon.stack>0&talent.thorims_invocation.enabled
    { SPELL.WINDSTRIKE, function()
        return getMaelstromStacks() > 0 and hasTalent(TALENT.THORIMS_INVOCATION)
    end },
    { SPELL.ASCENDANCE, nil },
    -- stormstrike,if=buff.doom_winds.up&talent.thorims_invocation.enabled
    { SPELL.STORMSTRIKE, function()
        return hasBuff(BUFF.DOOM_WINDS) and hasTalent(TALENT.THORIMS_INVOCATION)
    end },
    -- crash_lightning,if=buff.doom_winds.up&talent.thorims_invocation.enabled
    { SPELL.CRASH_LIGHTNING, function()
        return hasBuff(BUFF.DOOM_WINDS) and hasTalent(TALENT.THORIMS_INVOCATION)
    end },
    { SPELL.TEMPEST, function()
        return getMaelstromStacks() == 10
    end },
    { SPELL.LIGHTNING_BOLT, function()
        return getMaelstromStacks() == 10
    end },
    { SPELL.STORMSTRIKE, function()
        return getChargesFractional(SPELL.STORMSTRIKE) >= 1.8
    end },
    { SPELL.LAVA_LASH, nil },
    { SPELL.STORMSTRIKE, nil },
    { SPELL.VOLTAIC_BLAZE, nil },
    { SPELL.SUNDERING, nil },
    { SPELL.LIGHTNING_BOLT, function()
        return getMaelstromStacks() >= 8
    end },
    { SPELL.CRASH_LIGHTNING, nil },
    { SPELL.LIGHTNING_BOLT, function()
        return getMaelstromStacks() >= 5
    end },
}

APL.single_totemic = {
    -- voltaic_blaze,if=dot.flame_shock.remains=0
    { SPELL.VOLTAIC_BLAZE, function()
        return getAuraRemains(DEBUFF.FLAME_SHOCK, "target", "HARMFUL") == 0
    end },
    { SPELL.SURGING_TOTEM, nil },
    -- call_action_list,name=buffs
    { sublist = APL.buffs },
    { SPELL.LAVA_LASH, function()
        return hasBuff(BUFF.WHIRLING_FIRE) or hasBuff(BUFF.HOT_HAND)
    end },
    -- sundering,if=talent.surging_elements.enabled|buff.whirling_earth.up|talent.feral_spirit.enabled
    { SPELL.SUNDERING, function()
        return hasTalent(TALENT.SURGING_ELEMENTS)
            or hasBuff(BUFF.WHIRLING_EARTH)
            or hasTalent(TALENT.FERAL_SPIRIT)
    end },
    { SPELL.DOOM_WINDS, nil },
    { SPELL.CRASH_LIGHTNING, function()
        return not hasBuff(BUFF.CRASH_LIGHTNING) or hasTalent(TALENT.STORM_UNLEASHED)
    end },
    { SPELL.PRIMORDIAL_STORM, function()
        local mw = getMaelstromStacks()
        return mw >= 10
            or (getAuraRemains(BUFF.PRIMORDIAL_STORM, "player", "HELPFUL") < 3.5
                and mw >= 5)
    end },
    -- windstrike,if=talent.thorims_invocation.enabled&buff.ascendance.up
    { SPELL.WINDSTRIKE, function()
        return hasTalent(TALENT.THORIMS_INVOCATION) and hasBuff(BUFF.ASCENDANCE)
    end },
    -- ascendance,if=ti_lightning_bolt
    -- ti_lightning_bolt ≈ Thorim's Invocation learned & Ascendance not up
    { SPELL.ASCENDANCE, function()
        return hasTalent(TALENT.THORIMS_INVOCATION) and not hasBuff(BUFF.ASCENDANCE)
    end },
    -- crash_lightning,if=talent.thorims_invocation.enabled&buff.doom_winds.up|buff.ascendance.up
    { SPELL.CRASH_LIGHTNING, function()
        return (hasTalent(TALENT.THORIMS_INVOCATION) and hasBuff(BUFF.DOOM_WINDS))
            or hasBuff(BUFF.ASCENDANCE)
    end },
    { SPELL.STORMSTRIKE, function()
        return hasTalent(TALENT.THORIMS_INVOCATION) and hasBuff(BUFF.DOOM_WINDS)
    end },
    -- lightning_bolt,if=talent.elemental_tempo.enabled&(buff.maelstrom_weapon.stack>=5&
    --   (cooldown.lava_lash.remains>gcd.max)&(cooldown.lava_lash.remains<=buff.maelstrom_weapon.stack*0.3)
    --   |buff.maelstrom_weapon.stack>=10)
    { SPELL.LIGHTNING_BOLT, function()
        local mw = getMaelstromStacks()
        if not hasTalent(TALENT.ELEMENTAL_TEMPO) then return false end
        if mw >= 10 then return true end
        local llCD = getCDRemains(SPELL.LAVA_LASH)
        -- gcd.max approximated as 1.5 seconds
        return mw >= 5 and llCD > 1.5 and llCD <= mw * 0.3
    end },
    { SPELL.CRASH_LIGHTNING, function()
        return not hasBuff(BUFF.CRASH_LIGHTNING)
    end },
    { SPELL.LAVA_LASH, nil },
    { SPELL.SUNDERING, function()
        return getCDRemains(SPELL.SURGING_TOTEM) > 25
    end },
    { SPELL.STORMSTRIKE, nil },
    { SPELL.VOLTAIC_BLAZE, nil },
    { SPELL.CRASH_LIGHTNING, nil },
    { SPELL.LIGHTNING_BOLT, function()
        return getMaelstromStacks() >= 5
    end },
}

APL.aoe = {
    { SPELL.VOLTAIC_BLAZE, function()
        return hasTalent(SPELL.SURGING_TOTEM)
            and getAuraRemains(DEBUFF.FLAME_SHOCK, "target", "HARMFUL") == 0
    end },
    { SPELL.SURGING_TOTEM, nil },
    -- ascendance,if=ti_chain_lightning
    -- ti_chain_lightning ≈ Thorim's Invocation learned & Ascendance not up
    { SPELL.ASCENDANCE, function()
        return hasTalent(TALENT.THORIMS_INVOCATION) and not hasBuff(BUFF.ASCENDANCE)
    end },
    -- call_action_list,name=buffs
    { sublist = APL.buffs },
    -- sundering,if=talent.surging_elements.enabled|buff.whirling_earth.up
    { SPELL.SUNDERING, function()
        return hasTalent(TALENT.SURGING_ELEMENTS) or hasBuff(BUFF.WHIRLING_EARTH)
    end },
    { SPELL.LAVA_LASH, function()
        return hasBuff(BUFF.WHIRLING_FIRE)
    end },
    { SPELL.DOOM_WINDS, nil },
    { SPELL.CRASH_LIGHTNING, function()
        return hasTalent(TALENT.THORIMS_INVOCATION)
            and hasBuff(BUFF.WHIRLING_AIR)
            and (hasBuff(BUFF.DOOM_WINDS) or hasBuff(BUFF.ASCENDANCE))
    end },
    { SPELL.WINDSTRIKE, function()
        return hasTalent(TALENT.THORIMS_INVOCATION)
            and hasBuff(BUFF.WHIRLING_AIR)
            and hasBuff(BUFF.ASCENDANCE)
    end },
    { SPELL.STORMSTRIKE, function()
        return hasTalent(TALENT.THORIMS_INVOCATION)
            and hasBuff(BUFF.WHIRLING_AIR)
            and hasBuff(BUFF.DOOM_WINDS)
    end },
    -- lava_lash,if=talent.splitstream.enabled&buff.hot_hand.up
    { SPELL.LAVA_LASH, function()
        return hasTalent(TALENT.SPLITSTREAM) and hasBuff(BUFF.HOT_HAND)
    end },
    { SPELL.TEMPEST, function()
        local mw = getMaelstromStacks()
        return mw >= 10
            and (not hasBuff(BUFF.ASCENDANCE) or not hasBuff(BUFF.DOOM_WINDS))
    end },
    { SPELL.PRIMORDIAL_STORM, function()
        return getMaelstromStacks() >= 10
    end },
    -- voltaic_blaze,if=talent.fire_nova.enabled
    { SPELL.VOLTAIC_BLAZE, function()
        return hasTalent(TALENT.FIRE_NOVA)
    end },
    { SPELL.CRASH_LIGHTNING, nil },
    { SPELL.WINDSTRIKE, nil },
    { SPELL.STORMSTRIKE, function()
        return hasBuff(BUFF.DOOM_WINDS)
    end },
    { SPELL.CHAIN_LIGHTNING, function()
        local threshold = hasTalent(SPELL.SURGING_TOTEM) and 10 or 9
        return getMaelstromStacks() >= threshold
    end },
    { SPELL.SUNDERING, function()
        return hasTalent(TALENT.FERAL_SPIRIT)
    end },
    { SPELL.VOLTAIC_BLAZE, nil },
    -- lava_lash,if=pet.searing_totem.active
    { SPELL.LAVA_LASH, function()
        return isSearingTotemActive()
    end },
    { SPELL.STORMSTRIKE, function()
        local cf = getChargesFractional(SPELL.STORMSTRIKE)
        local data = getAuraData("player", BUFF.CONVERGING_STORMS, "HELPFUL")
        local csMax   = data and (data.maxStacks or 6) or 6
        local csStack = data and (data.applications or 0) or 0
        return cf >= 1.8 or csStack == csMax
    end },
    { SPELL.SUNDERING, function()
        return getCDRemains(SPELL.SURGING_TOTEM) > 25
    end },
    { SPELL.STORMSTRIKE, function()
        return not hasTalent(SPELL.SURGING_TOTEM)
    end },
    { SPELL.LAVA_LASH, nil },
    { SPELL.STORMSTRIKE, nil },
    { SPELL.CHAIN_LIGHTNING, function()
        return getMaelstromStacks() >= 5
    end },
}

-- ============================================================
-- GetNextSpell Override
-- ============================================================
function SE:GetNextSpell(unitState)
    local enemies = getActiveEnemies()

    if enemies > 1 then
        return evalList(APL.aoe, unitState)
    end

    if hasTalent(SPELL.SURGING_TOTEM) then
        return evalList(APL.single_totemic, unitState)
    else
        return evalList(APL.single_sb, unitState)
    end
end

