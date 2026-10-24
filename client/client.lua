QBCore = exports['qb-core']:GetCoreObject()

-- ========================
-- State
-- ========================

local stateStopped = 0

-- Every speaker on the server, keyed by owner server id, as last sent by the server.
-- receivedAt is this client's GetGameTimer() at arrival; positions are extrapolated from it.
local emitters = {}

-- Speakers that currently hold a YouTube player in the NUI page, with the volume (0 - 100) last sent for each.
local activeVolumes = {}

local nuiReady = false
local listenerVolume = Config.defaultListenerVolume
local lastOwnNotify = 0

-- ========================
-- Helpers
-- ========================

local function RefreshListenerVolume(playerData)
    local metadata = playerData and playerData.metadata and playerData.metadata['FranticYoutube']
    local volume = metadata and tonumber(metadata.ListenerVolume)
    listenerVolume = volume and math.max(0.0, math.min(1.0, volume)) or Config.defaultListenerVolume
end

local function GetOwnServerId()
    return GetPlayerServerId(PlayerId())
end

local function GetEmitterPosition(emitter)
    local position = emitter.position
    if emitter.state == 1 then
        position = position + (GetGameTimer() - emitter.receivedAt) / 1000.0
    end
    if emitter.duration > 0 then
        position = math.min(position, emitter.duration)
    end
    return position
end

-- Field names kept from the old broadcast table, so resources written against it (the phone) read the same keys.
local function BuildPublicVideoData(emitter)
    return {
        videoUrl = emitter.videoId,
        title = emitter.title,
        author = emitter.author,
        videoDuration = emitter.duration,
        videoCurrentTime = GetEmitterPosition(emitter),
        videoState = emitter.state,
        videoLoaded = emitter.loaded,
        videoSpeakerVolume = emitter.speakerVolume,
    }
end

local function NotifyOwnVideo()
    lastOwnNotify = GetGameTimer()
    local emitter = emitters[GetOwnServerId()]
    TriggerEvent('Frantic_Youtube:client:OwnVideoUpdated', emitter and BuildPublicVideoData(emitter) or nil)
end

-- NUI messages are JSON, so ids go over as strings; numeric keys would turn the table into a sparse array.
local function BuildNuiEmitter(emitter)
    return {
        videoId = emitter.videoId,
        state = emitter.state,
        position = GetEmitterPosition(emitter),
        duration = emitter.duration,
    }
end

local function SendEmitterToNui(serverId)
    if not nuiReady then
        return
    end

    local emitter = emitters[serverId]
    SendNUIMessage({
        action = 'SetEmitter',
        id = tostring(serverId),
        emitter = emitter and BuildNuiEmitter(emitter) or false,
    })
end

local function SendAllEmittersToNui()
    if not nuiReady then
        return
    end

    local payload = {}
    for serverId, emitter in pairs(emitters) do
        payload[tostring(serverId)] = BuildNuiEmitter(emitter)
    end
    SendNUIMessage({ action = 'SetEmitters', emitters = payload })
end

-- ========================
-- Speaker Selection
-- ========================

-- Picks which speakers get one of the few YouTube players and at what volume.
-- Out-of-scope players (GetPlayerFromServerId == -1) are hundreds of metres away, far outside maxDistance, so they are simply skipped; the server no longer needs to send positions.
local function UpdateActiveEmitters()
    local ownServerId = GetOwnServerId()
    local ownCoords = GetEntityCoords(PlayerPedId())
    local candidates = {}

    for serverId, emitter in pairs(emitters) do
        if emitter.state ~= stateStopped then
            local distance = nil
            if serverId == ownServerId then
                distance = 0.0
            else
                local player = GetPlayerFromServerId(serverId)
                if player ~= -1 then
                    distance = #(ownCoords - GetEntityCoords(GetPlayerPed(player)))
                end
            end

            -- A speaker already holding a player keeps it out to releaseDistance (silent past maxDistance), so the edge doesn't flicker.
            local limit = activeVolumes[serverId] and Config.releaseDistance or Config.maxDistance
            if distance and distance < limit then
                local attenuation = math.max(0.0, 1.0 - distance / Config.maxDistance)
                candidates[#candidates + 1] = {
                    serverId = serverId,
                    distance = distance,
                    volume = math.floor(100.0 * attenuation * emitter.speakerVolume * listenerVolume + 0.5),
                }
            end
        end
    end

    table.sort(candidates, function(a, b)
        return a.distance < b.distance
    end)

    local newVolumes = {}
    local changed = false
    for i = 1, math.min(#candidates, Config.maxActivePlayers) do
        local candidate = candidates[i]
        newVolumes[candidate.serverId] = candidate.volume
        if activeVolumes[candidate.serverId] ~= candidate.volume then
            changed = true
        end
    end
    for serverId in pairs(activeVolumes) do
        if newVolumes[serverId] == nil then
            changed = true
        end
    end

    activeVolumes = newVolumes

    if changed and nuiReady then
        local payload = {}
        for serverId, volume in pairs(newVolumes) do
            payload[tostring(serverId)] = volume
        end
        SendNUIMessage({ action = 'SetActive', volumes = payload })
    end
end

CreateThread(function()
    while true do
        UpdateActiveEmitters()

        if emitters[GetOwnServerId()] and GetGameTimer() - lastOwnNotify >= 1000 then
            NotifyOwnVideo()
        end

        Wait(next(emitters) and Config.clientRefreshRate or 1000)
    end
end)

-- ========================
-- Server Events
-- ========================

RegisterNetEvent('Frantic_Youtube:client:SetEmitter', function(serverId, emitter)
    serverId = tonumber(serverId)
    if not serverId then
        return
    end

    if emitter then
        emitter.receivedAt = GetGameTimer()
    end
    emitters[serverId] = emitter
    SendEmitterToNui(serverId)

    if serverId == GetOwnServerId() then
        NotifyOwnVideo()
    end
end)

RegisterNetEvent('Frantic_Youtube:client:SetEmitters', function(allEmitters)
    local now = GetGameTimer()
    emitters = {}
    for serverId, emitter in pairs(allEmitters or {}) do
        emitter.receivedAt = now
        emitters[tonumber(serverId)] = emitter
    end
    SendAllEmittersToNui()
    NotifyOwnVideo()
end)

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    RefreshListenerVolume(QBCore.Functions.GetPlayerData())
end)

RegisterNetEvent('QBCore:Player:SetPlayerData', function(playerData)
    RefreshListenerVolume(playerData)
end)

CreateThread(function()
    RefreshListenerVolume(QBCore.Functions.GetPlayerData())
    TriggerServerEvent('Frantic_Youtube:server:RequestEmitters')
end)

-- ========================
-- NUI Callbacks
-- ========================

RegisterNUICallback('NuiReady', function(_, cb)
    nuiReady = true
    SendNUIMessage({
        action = 'Init',
        maxActivePlayers = Config.maxActivePlayers,
        driftTolerance = Config.driftTolerance,
        idlePlayerLifetime = Config.idlePlayerLifetime,
    })
    SendAllEmittersToNui()

    -- Forget what was sent before the page existed, so the next update sends the full active set.
    activeVolumes = {}
    cb('ok')
end)

-- The page reports for any speaker it plays; only the owner's report means anything to the server.
RegisterNUICallback('VideoReady', function(data, cb)
    if tonumber(data.id) == GetOwnServerId() then
        TriggerServerEvent('Frantic_Youtube:server:ReportVideoReady', { videoId = data.videoId, duration = data.duration })
    end
    cb('ok')
end)

RegisterNUICallback('VideoError', function(data, cb)
    if tonumber(data.id) == GetOwnServerId() then
        TriggerServerEvent('Frantic_Youtube:server:ReportVideoError', { videoId = data.videoId, code = data.code })
    end
    cb('ok')
end)

-- ========================
-- Commands & Exports
-- ========================

RegisterCommand('playvideo', function(_, args)
    if not args[1] then
        QBCore.Functions.Notify('You need to input a video URL or ID', 'error')
        return
    end

    QBCore.Functions.TriggerCallback('Frantic_Youtube:server:PlayVideoWithID', function(result)
        if not result then
            QBCore.Functions.Notify('Couldn\'t play that video', 'error')
        end
    end, args[1])
end, false)

-- Current state of this player's own speaker, or nil if it has none.
exports('GetOwnVideoData', function()
    local emitter = emitters[GetOwnServerId()]
    return emitter and BuildPublicVideoData(emitter) or nil
end)

-- Current state of any player's speaker by server id, or nil if they have none.
exports('GetVideoData', function(serverId)
    local emitter = emitters[tonumber(serverId)]
    return emitter and BuildPublicVideoData(emitter) or nil
end)
