-- NetworkState.lua
-- Implements the dynamic part of the "The Sovereign Individual" UA:
--   +1 Gold and +1 Science per City-State alliance, applied each turn.
-- Static bonuses (+2 Gold, +1 Science in every city, CS influence boost)
-- are handled via XML in CIV5Traits_NetworkState.xml.

local CIVILIZATION_TYPE = "CIVILIZATION_NETWORK_STATE"

-- Cache the civilization type ID after the game loads
local networkStateCivType = nil

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

-- Returns the number of City-States the given player is allied with
local function CountCityStateAlliances(playerID)
    local count = 0
    for i = GameDefines.MAX_MAJOR_CIVS, GameDefines.MAX_CIV_PLAYERS - 1 do
        local minorPlayer = Players[i]
        if minorPlayer ~= nil and minorPlayer:IsAlive() and minorPlayer:IsMinorCiv() then
            if minorPlayer:GetAlly() == playerID then
                count = count + 1
            end
        end
    end
    return count
end

-- Apply per-turn bonuses for the Network State UA
local function NetworkState_PlayerDoTurn(playerID)
    local player = Players[playerID]
    if player == nil or not player:IsAlive() or player:IsMinorCiv() or player:IsBarbarian() then
        return
    end

    -- Only apply to Network State civilization
    if player:GetCivilizationType() ~= GetNetworkStateCivType() then
        return
    end

    local allyCount = CountCityStateAlliances(playerID)
    if allyCount <= 0 then return end

    -- +1 Gold per City-State ally
    player:ChangeGold(allyCount)

    -- +1 Science per City-State ally: add research progress to current tech
    local currentTech = player:GetCurrentResearch()
    if currentTech >= 0 then
        local team = Teams[player:GetTeam()]
        if team ~= nil then
            team:GetTeamTechs():ChangeResearchProgress(currentTech, allyCount)
        end
    end
end

-- Hook into the turn processing event
GameEvents.PlayerDoTurn.Add(NetworkState_PlayerDoTurn)

-- Notification on first turn to confirm the mod loaded
local function NetworkState_GameStart()
    local activePlayerID = Game.GetActivePlayer()
    local player = Players[activePlayerID]
    if player ~= nil and player:IsAlive() then
        if player:GetCivilizationType() == GetNetworkStateCivType() then
            player:AddNotification(
                NotificationTypes.NOTIFICATION_GENERIC,
                "The Network State is ready. Each City-State alliance yields +1 [ICON_GOLD] Gold and +1 [ICON_RESEARCH] Science per turn.",
                "The Sovereign Individual",
                -1, -1
            )
        end
    end
end

Events.LoadScreenClose.Add(NetworkState_GameStart)

print("[NetworkState] Mod loaded successfully.")
