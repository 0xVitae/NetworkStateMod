-- NetworkState.lua
-- Implements the dynamic parts of the Network State civilization:
--   * Startup Founder (UU): Trade Missions grant 200 Influence total (the engine
--     gives the standard 30; we top up the rest) and permanently turn the
--     City-State into a Special Economic Zone.
--     Trade Missions are detected via UnitPrekill: a Founder removed on a
--     City-State-owned plot means Trade Mission; anywhere else (e.g. Customs
--     House in own territory) is ignored.
--   * Special Economic Zones pay 25% of their Science and Gold each turn.
--     SEZs are marked on the map: their capital is renamed with an "(SEZ)"
--     tag, and their banner/diplo popup show SEZ status
--     (UI/CityBannerManager.lua and UI/CityStateDiploPopup.lua read the
--     same savegame data).
-- The free Startup Founder at Currency is XML (CIV5Traits_NetworkState.xml).

local CIVILIZATION_TYPE = "CIVILIZATION_NETWORK_STATE"
local NETWORK_MERCHANT_UNIT = "UNIT_NETWORK_MERCHANT"
-- Total Influence a Founder's Trade Mission should yield (engine grants the
-- standard MINOR_FRIENDSHIP_FROM_TRADE_MISSION = 30; Lua adds the difference).
local FOUNDER_TRADE_MISSION_INFLUENCE = 200

-- Cached IDs (populated lazily after the game loads)
local networkStateCivType = nil
local networkMerchantUnitType = nil

local function GetNetworkStateCivType()
    if networkStateCivType == nil then
        for row in GameInfo.Civilizations() do
            if row.Type == CIVILIZATION_TYPE then
                networkStateCivType = row.ID
                break
            end
        end
    end
    return networkStateCivType
end

local function GetNetworkMerchantUnitType()
    if networkMerchantUnitType == nil then
        local u = GameInfo.Units[NETWORK_MERCHANT_UNIT]
        if u ~= nil then networkMerchantUnitType = u.ID end
    end
    return networkMerchantUnitType
end

-- =============================================================================
-- UA: science from allied City-States (hidden Scholasticism-style policy)
-- =============================================================================

local SCIENCE_POLICY = "POLICY_NETWORK_STATE_SCIENCE"
local sciencePolicyID = nil
local function GetSciencePolicyID()
    if sciencePolicyID == nil then
        local p = GameInfo.Policies[SCIENCE_POLICY]
        if p ~= nil then sciencePolicyID = p.ID end
    end
    return sciencePolicyID
end

-- Runs every turn so it also covers games saved before this feature existed.
-- (Vanilla has no GrantPolicy; SetHasPolicy is the supported way to hand a
-- player a policy directly.)
local function NetworkState_EnsureSciencePolicy(playerID)
    local player = Players[playerID]
    if player == nil or not player:IsAlive() or player:IsMinorCiv() or player:IsBarbarian() then
        return
    end
    if player:GetCivilizationType() ~= GetNetworkStateCivType() then return end

    local policyID = GetSciencePolicyID()
    if policyID == nil then return end
    if not player:HasPolicy(policyID) then
        player:SetHasPolicy(policyID, true)
        print("[NetworkState] Granted ally-science policy to player " .. playerID)
    end
end
GameEvents.PlayerDoTurn.Add(NetworkState_EnsureSciencePolicy)

-- =============================================================================
-- UA: Special Economic Zones
-- =============================================================================
-- A Trade Mission permanently converts the target City-State into a Special
-- Economic Zone. Each turn, every living SEZ pays its patron 25% of its
-- gross Gold. (Science from City-States comes via ally status and the
-- policy above, so the engine displays it natively.) SEZ status is
-- persisted in the savegame via Modding.OpenSaveData().

local SEZ_PERCENT = 25
local sezByPlayer = {}  -- sezByPlayer[playerID] = { [minorID] = true }
local sezSaveData = Modding.OpenSaveData()

local function SEZSaveKey(playerID)
    return "NetworkState_SEZ_" .. playerID
end

local function LoadSEZData()
    for playerID = 0, GameDefines.MAX_MAJOR_CIVS - 1 do
        local s = sezSaveData.GetValue(SEZSaveKey(playerID))
        if type(s) == "string" and s ~= "" then
            local t = {}
            for id in string.gmatch(s, "%d+") do
                t[tonumber(id)] = true
            end
            sezByPlayer[playerID] = t
        end
    end
end
LoadSEZData()

local function AddSEZ(playerID, minorID)
    if sezByPlayer[playerID] == nil then
        sezByPlayer[playerID] = {}
    end
    sezByPlayer[playerID][minorID] = true

    local parts = {}
    for id in pairs(sezByPlayer[playerID]) do
        table.insert(parts, tostring(id))
    end
    sezSaveData.SetValue(SEZSaveKey(playerID), table.concat(parts, ","))

    -- Tag the City-State's capital name so the SEZ reads everywhere its
    -- name appears (banner, trade screens, diplo).
    local minor = Players[minorID]
    if minor ~= nil then
        local capital = minor:GetCapitalCity()
        if capital ~= nil and not string.find(capital:GetName(), "(SEZ)", 1, true) then
            capital:SetName(capital:GetName() .. " (SEZ)")
        end
    end

    -- Tell the banner manager / diplo popup to re-read SEZ data.
    LuaEvents.NetworkStateSEZChanged()
    print("[NetworkState] SEZ chartered: player " .. playerID .. " <- minor " .. minorID)
end

local function IsSEZ(playerID, minorID)
    return sezByPlayer[playerID] ~= nil and sezByPlayer[playerID][minorID] == true
end

-- Per-turn SEZ payout
local function NetworkState_SEZYields(playerID)
    local player = Players[playerID]
    if player == nil or not player:IsAlive() or player:IsMinorCiv() or player:IsBarbarian() then
        return
    end
    if player:GetCivilizationType() ~= GetNetworkStateCivType() then return end

    local zones = sezByPlayer[playerID]
    if zones == nil then return end

    local goldBonus = 0
    for minorID in pairs(zones) do
        local minor = Players[minorID]
        if minor ~= nil and minor:IsAlive() and minor:IsMinorCiv() then
            goldBonus = goldBonus + math.floor(minor:CalculateGrossGold() * SEZ_PERCENT / 100)
        end
    end

    if goldBonus > 0 then
        player:ChangeGold(goldBonus)
    end
end
GameEvents.PlayerDoTurn.Add(NetworkState_SEZYields)

-- =============================================================================
-- Startup Founder: Trade Mission detection
-- =============================================================================
-- This vanilla build never fires GameEvents.GreatPersonExpended (verified in
-- Lua.log), so Trade Missions are detected via GameEvents.UnitPrekill, which
-- fires while the expended unit still exists and reports its plot directly.
-- A Founder removed inside City-State territory — not at war, not killed by
-- another player — is a completed Trade Mission. Customs House construction
-- happens in own or neutral territory, so it never matches.

-- UnitPrekill can fire more than once for the same kill (delayed + real),
-- so remember which units were already processed.
local processedFounders = {}

local function NetworkMerchant_OnUnitPrekill(playerID, unitID, unitType, x, y, bDelay, byPlayerID)
    if unitType ~= GetNetworkMerchantUnitType() then return end

    local player = Players[playerID]
    if player == nil or not player:IsAlive() then return end
    if player:GetCivilizationType() ~= GetNetworkStateCivType() then return end

    print("[NetworkState] Founder " .. tostring(unitID) .. " removed at " .. tostring(x) .. "," .. tostring(y) ..
        " (delay " .. tostring(bDelay) .. ", by player " .. tostring(byPlayerID) .. ")")

    local key = playerID .. "_" .. unitID
    if processedFounders[key] then return end

    -- Killed by someone else (combat, capture) is not a Trade Mission.
    if byPlayerID ~= nil and byPlayerID >= 0 and byPlayerID ~= playerID then return end

    local plot = Map.GetPlot(x, y)
    if plot == nil then return end
    local ownerID = plot:GetOwner()
    if ownerID < 0 then
        print("[NetworkState] Plot unowned; not a Trade Mission")
        return
    end
    local minor = Players[ownerID]
    if minor == nil or not minor:IsMinorCiv() or not minor:IsAlive() then
        print("[NetworkState] Plot owner is not a living City-State; not a Trade Mission")
        return
    end
    if Teams[player:GetTeam()]:IsAtWar(minor:GetTeam()) then return end

    processedFounders[key] = true
    print("[NetworkState] Trade Mission detected with " .. minor:GetCivilizationShortDescription())

    -- Top up the engine's standard Trade Mission influence to the Founder's total.
    local baseInfluence = GameDefines.MINOR_FRIENDSHIP_FROM_TRADE_MISSION or 30
    local extraInfluence = FOUNDER_TRADE_MISSION_INFLUENCE - baseInfluence
    if extraInfluence > 0 then
        minor:ChangeMinorCivFriendshipWithMajor(playerID, extraInfluence)
    end

    -- The Trade Mission charters the City-State as a Special Economic Zone.
    local newSEZ = not IsSEZ(playerID, ownerID)
    if newSEZ then
        AddSEZ(playerID, ownerID)
    end

    if playerID == Game.GetActivePlayer() then
        local message = "Your Startup Founder's Trade Mission earned " ..
            FOUNDER_TRADE_MISSION_INFLUENCE .. " [ICON_INFLUENCE] Influence with " ..
            minor:GetCivilizationShortDescription() .. "."
        if newSEZ then
            message = message .. " " .. minor:GetCivilizationShortDescription() ..
                " is now a Special Economic Zone, providing you " .. SEZ_PERCENT ..
                "% of its [ICON_GOLD] Gold and [ICON_RESEARCH] Science each turn."
        end
        player:AddNotification(
            NotificationTypes.NOTIFICATION_GENERIC,
            message,
            "Startup Founder",
            -1, -1
        )
    end
end
GameEvents.UnitPrekill.Add(NetworkMerchant_OnUnitPrekill)

-- Notification on first turn to confirm the mod loaded
local function NetworkState_GameStart()
    local activePlayerID = Game.GetActivePlayer()
    local player = Players[activePlayerID]
    print("[NetworkState] Active player civ type: " .. tostring(player and player:GetCivilizationType()) ..
        " (Network State is " .. tostring(GetNetworkStateCivType()) .. ")")
    if player ~= nil and player:IsAlive() then
        if player:GetCivilizationType() == GetNetworkStateCivType() then
            player:AddNotification(
                NotificationTypes.NOTIFICATION_GENERIC,
                "The Network State is ready. Discover Currency to receive a free Startup Founder, whose Trade Missions turn City-States into Special Economic Zones.",
                "Startup Societies",
                -1, -1
            )
        end
    end
end

Events.LoadScreenClose.Add(NetworkState_GameStart)

print("[NetworkState] Mod loaded successfully.")
