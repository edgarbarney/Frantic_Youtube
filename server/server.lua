QBCore = exports['qb-core']:GetCoreObject()

-- ========================
-- State
-- ========================

local stateStopped = 0
local statePlaying = 1
local statePaused = 2

-- Speakers that currently have a video, keyed by the owner's server id.
-- An entry only exists between a play request and the owner dropping; nothing creates one as a side effect of a lookup.
-- Position is stored as an anchor (position at anchorTime) instead of a ticking counter, so it never drifts and needs no per-second update.
local emitters = {}

-- Per-player copy of their database row, so read-modify-write requests from one player can't interleave and lose each other's changes.
local citizenCache = {}

-- oEmbed results by video id. Durations are filled in once an owner's player reports them.
local metadataCache = {}
local metadataCacheSize = 0
local maxMetadataCacheSize = 1000

local lastPlayRequest = {}

local videoIdPatterns = {
    '[?&]v=([%w_-]+)', -- Normal
    'youtu%.be/([%w_-]+)', -- Shortened
    'embed/([%w_-]+)', -- Embed
    'shorts/([%w_-]+)', -- Shorts
    'live/([%w_-]+)', -- Live
}

-- ========================
-- Helpers
-- ========================

-- Returns nil for anything that isn't a finite number, so NaN/inf from a client can't poison the timeline.
local function ToClampedNumber(value, min, max)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge then
        return nil
    end
    return math.max(min, math.min(max, value))
end

local function ExtractVideoId(input)
    if type(input) ~= 'string' or #input > 300 then
        return nil
    end

    if #input == 11 and input:match('^[%w_-]+$') then
        return input
    end

    for _, pattern in ipairs(videoIdPatterns) do
        local id = input:match(pattern)
        if id and #id == 11 then
            return id
        end
    end

    return nil
end

local function GetYoutubeMetadata(Player)
    local metadata = Player.PlayerData.metadata['FranticYoutube'] or {}
    return {
        ListenerVolume = ToClampedNumber(metadata.ListenerVolume, 0.0, 1.0) or Config.defaultListenerVolume,
        SpeakerVolume = ToClampedNumber(metadata.SpeakerVolume, 0.0, 1.0) or Config.defaultSpeakerVolume,
    }
end

-- Lists used to be stored with a [0] first index, which JSON turns into an object with "0", "1"... keys.
-- This turns both that legacy shape and plain arrays into a 1-based Lua array.
-- Every entry is a video or playlist table; anything else is corrupt and dropped.
local function NormaliseList(value)
    if type(value) ~= 'table' then
        return {}
    end

    local keys = {}
    for key, entry in pairs(value) do
        local index = tonumber(key)
        if index and type(entry) == 'table' then
            keys[#keys + 1] = { index = index, key = key }
        end
    end
    table.sort(keys, function(a, b) return a.index < b.index end)

    local list = {}
    for _, entry in ipairs(keys) do
        list[#list + 1] = value[entry.key]
    end
    return list
end

local function DecodeList(text)
    if type(text) ~= 'string' or text == '' then
        return {}
    end

    local ok, value = pcall(json.decode, text)
    if not ok then
        return {}
    end
    return NormaliseList(value)
end

local function NormalisePlaylists(playlists)
    local nextId = 1
    for _, playlist in ipairs(playlists) do
        local id = tonumber(playlist.id)
        if id and id >= nextId then
            nextId = id + 1
        end
    end

    local seenIds = {}
    for _, playlist in ipairs(playlists) do
        playlist.videos = NormaliseList(playlist.videos)
        local id = tonumber(playlist.id)
        if not id or seenIds[id] then
            id = nextId
            nextId = nextId + 1
        end
        playlist.id = id
        seenIds[id] = true
    end
    return playlists
end

local function FindVideoIndex(list, videoId)
    for index, video in ipairs(list) do
        if video.url == videoId then
            return index
        end
    end
    return nil
end

-- ========================
-- Citizen Data
-- ========================

local function GetCitizenData(src)
    local Player = QBCore.Functions.GetPlayer(src)
    if not Player then
        return nil
    end

    local citizenId = Player.PlayerData.citizenid
    local cached = citizenCache[src]
    if cached and cached.citizenId == citizenId then
        while cached.loading do
            Wait(50)
        end
        return (not cached.failed) and cached or nil
    end

    cached = { citizenId = citizenId, loading = true, videos = {}, playlists = {} }
    citizenCache[src] = cached

    local ok, err = pcall(function()
        local row = MySQL.single.await('SELECT videos, playlists FROM frantic_youtube_citizens WHERE citizenid = ?', { citizenId })
        if row then
            cached.videos = DecodeList(row.videos)
            cached.playlists = NormalisePlaylists(DecodeList(row.playlists))
        else
            MySQL.insert.await('INSERT INTO frantic_youtube_citizens (citizenid, playlists, videos) VALUES (?, ?, ?)', { citizenId, '[]', '[]' })
        end
    end)

    cached.loading = false
    if not ok then
        print(('^1[Frantic_Youtube] Failed to load data for %s: %s^7'):format(citizenId, err))
        cached.failed = true
        if citizenCache[src] == cached then
            citizenCache[src] = nil
        end
        return nil
    end

    return cached
end

local function SaveVideos(citizenData)
    MySQL.update('UPDATE frantic_youtube_citizens SET videos = ? WHERE citizenid = ?', { json.encode(citizenData.videos), citizenData.citizenId })
end

local function SavePlaylists(citizenData)
    MySQL.update('UPDATE frantic_youtube_citizens SET playlists = ? WHERE citizenid = ?', { json.encode(citizenData.playlists), citizenData.citizenId })
end

local function AddToHistory(citizenData, video)
    local index = FindVideoIndex(citizenData.videos, video.url)
    if index then
        table.remove(citizenData.videos, index)
    end
    citizenData.videos[#citizenData.videos + 1] = video

    while #citizenData.videos > Config.maxHistory do
        table.remove(citizenData.videos, 1)
    end
    SaveVideos(citizenData)
end

-- Fill in a duration that wasn't known when the video was first saved.
local function UpdateStoredDuration(citizenData, videoId, duration)
    local index = FindVideoIndex(citizenData.videos, videoId)
    if index and (tonumber(citizenData.videos[index].duration) or 0) <= 0 then
        citizenData.videos[index].duration = duration
        SaveVideos(citizenData)
    end

    local playlistsChanged = false
    for _, playlist in ipairs(citizenData.playlists) do
        local playlistIndex = FindVideoIndex(playlist.videos, videoId)
        if playlistIndex and (tonumber(playlist.videos[playlistIndex].duration) or 0) <= 0 then
            playlist.videos[playlistIndex].duration = duration
            playlistsChanged = true
        end
    end
    if playlistsChanged then
        SavePlaylists(citizenData)
    end
end

-- ========================
-- Video Metadata
-- ========================

-- Title and author come from YouTube's own oEmbed endpoint on the server, never from a client, so a modded client can't store arbitrary text in someone's library.
-- oEmbed also refuses videos that can't be embedded, which the iframe player couldn't play anyway.
local function FetchVideoMetadata(videoId)
    local cached = metadataCache[videoId]
    if cached then
        return cached
    end

    local p = promise.new()
    local settled = false
    local function Settle(value)
        if not settled then
            settled = true
            p:resolve(value)
        end
    end

    local url = 'https://www.youtube.com/oembed?format=json&url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3D' .. videoId
    PerformHttpRequest(url, function(status, body)
        if status ~= 200 or type(body) ~= 'string' then
            Settle(nil)
            return
        end

        local ok, data = pcall(json.decode, body)
        if not ok or type(data) ~= 'table' or type(data.title) ~= 'string' then
            Settle(nil)
            return
        end

        local author = type(data.author_name) == 'string' and data.author_name or ''
        Settle({
            title = data.title:sub(1, 200),
            author = (author:gsub(' %- Topic$', '')):sub(1, 100),
            duration = 0,
        })
    end, 'GET')

    SetTimeout(Config.metadataTimeout, function()
        Settle(nil)
    end)

    local metadata = Citizen.Await(p)
    if metadata then
        if metadataCacheSize >= maxMetadataCacheSize then
            metadataCache = {}
            metadataCacheSize = 0
        end
        if not metadataCache[videoId] then
            metadataCacheSize = metadataCacheSize + 1
        end
        metadataCache[videoId] = metadata
    end
    return metadata
end

local function BuildVideoEntry(videoId, metadata)
    return {
        url = videoId,
        title = metadata.title,
        author = metadata.author,
        duration = metadata.duration,
    }
end

-- ========================
-- Emitters
-- ========================

local function GetEmitterPosition(emitter)
    local position = emitter.anchorPosition
    if emitter.state == statePlaying then
        position = position + (GetGameTimer() - emitter.anchorTime) / 1000.0
    end
    if emitter.duration > 0 then
        position = math.min(position, emitter.duration)
    end
    return position
end

local function SetEmitterPosition(emitter, position)
    emitter.anchorPosition = position
    emitter.anchorTime = GetGameTimer()
end

-- Clients receive the position as of the moment this is sent and extrapolate from their own clock, so no shared clock is needed.
local function BuildEmitterPayload(emitter)
    return {
        videoId = emitter.videoId,
        title = emitter.title,
        author = emitter.author,
        duration = emitter.duration,
        state = emitter.state,
        position = GetEmitterPosition(emitter),
        speakerVolume = emitter.speakerVolume,
        loaded = emitter.loaded,
    }
end

local function BroadcastEmitter(src)
    local emitter = emitters[src]
    TriggerClientEvent('Frantic_Youtube:client:SetEmitter', -1, src, emitter and BuildEmitterPayload(emitter) or nil)
end

local function RemoveEmitter(src)
    if emitters[src] then
        emitters[src] = nil
        BroadcastEmitter(src)
    end
end

-- Only work left on the server: notice when a playing video reaches its end. Touches only speakers that are playing.
CreateThread(function()
    while true do
        Wait(1000)

        for src, emitter in pairs(emitters) do
            if emitter.state == statePlaying and emitter.duration > 0 and GetEmitterPosition(emitter) >= emitter.duration then
                SetEmitterPosition(emitter, emitter.duration)
                emitter.state = stateStopped
                BroadcastEmitter(src)
            end
        end
    end
end)

-- ========================
-- Playback Callbacks & Events
-- ========================

QBCore.Functions.CreateCallback('Frantic_Youtube:server:PlayVideoWithID', function(source, cb, data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    local videoId = ExtractVideoId(type(data) == 'table' and data.url or data)
    if not Player or not videoId then
        cb(false)
        return
    end

    local now = GetGameTimer()
    if lastPlayRequest[src] and now - lastPlayRequest[src] < Config.playCooldown then
        cb(false)
        return
    end
    lastPlayRequest[src] = now

    local metadata = FetchVideoMetadata(videoId)
    if not metadata or not QBCore.Functions.GetPlayer(src) then
        cb(false)
        return
    end

    local emitter = {
        videoId = videoId,
        title = metadata.title,
        author = metadata.author,
        duration = metadata.duration,
        state = statePlaying,
        speakerVolume = GetYoutubeMetadata(Player).SpeakerVolume,
        loaded = false,
        awaitingStart = true,
    }
    SetEmitterPosition(emitter, 0.0)
    emitters[src] = emitter
    BroadcastEmitter(src)

    local video = BuildVideoEntry(videoId, metadata)
    local citizenData = GetCitizenData(src)
    if citizenData then
        AddToHistory(citizenData, video)
    end

    cb(video)
end)

-- Returns title/author/duration for a video id or URL without playing it. Duration is 0 if no one has played it yet.
QBCore.Functions.CreateCallback('Frantic_Youtube:server:GetVideoData', function(source, cb, data)
    local videoId = ExtractVideoId(data)
    if not videoId then
        cb(false)
        return
    end

    local metadata = FetchVideoMetadata(videoId)
    cb(metadata and BuildVideoEntry(videoId, metadata) or false)
end)

RegisterNetEvent('Frantic_Youtube:server:SetVideoPlayingStatus', function(data)
    local src = source
    local emitter = emitters[src]
    local state = type(data) == 'table' and tonumber(data.state)
    if not emitter or (state ~= stateStopped and state ~= statePlaying and state ~= statePaused) or state == emitter.state then
        return
    end

    local position = GetEmitterPosition(emitter)
    if state == statePlaying and emitter.state == stateStopped then
        -- Pressing play on a finished video starts it over.
        position = 0.0
    end

    emitter.state = state
    SetEmitterPosition(emitter, position)
    BroadcastEmitter(src)
end)

RegisterNetEvent('Frantic_Youtube:server:SetVideoTime', function(data)
    local src = source
    local emitter = emitters[src]
    if not emitter or type(data) ~= 'table' then
        return
    end

    local maxPosition = emitter.duration > 0 and emitter.duration or Config.maxVideoDuration
    local position = ToClampedNumber(data.time, 0.0, maxPosition)
    if not position then
        return
    end

    if emitter.state == stateStopped and position < maxPosition then
        emitter.state = statePlaying
    end

    emitter.awaitingStart = false
    SetEmitterPosition(emitter, position)
    BroadcastEmitter(src)
end)

-- Sent by the owner's own player once the video actually starts.
-- Restarts the timeline at 0 so the owner doesn't miss the opening seconds spent buffering, and fills in the duration oEmbed can't provide.
RegisterNetEvent('Frantic_Youtube:server:ReportVideoReady', function(data)
    local src = source
    local emitter = emitters[src]
    if not emitter or type(data) ~= 'table' or data.videoId ~= emitter.videoId or emitter.loaded then
        return
    end

    emitter.loaded = true

    local duration = ToClampedNumber(data.duration, 0.0, Config.maxVideoDuration)
    if duration and duration > 0 and emitter.duration <= 0 then
        emitter.duration = duration

        local metadata = metadataCache[emitter.videoId]
        if metadata then
            metadata.duration = duration
        end

        local citizenData = citizenCache[src]
        if citizenData and not citizenData.loading then
            UpdateStoredDuration(citizenData, emitter.videoId, duration)
        end
    end

    if emitter.awaitingStart then
        emitter.awaitingStart = false
        SetEmitterPosition(emitter, 0.0)
    end

    BroadcastEmitter(src)
end)

-- Sent by the owner's own player when YouTube refuses the video (removed, private, embedding disabled...).
RegisterNetEvent('Frantic_Youtube:server:ReportVideoError', function(data)
    local src = source
    local emitter = emitters[src]
    if not emitter or type(data) ~= 'table' or data.videoId ~= emitter.videoId then
        return
    end

    emitter.state = stateStopped
    SetEmitterPosition(emitter, 0.0)
    BroadcastEmitter(src)
    TriggerClientEvent('QBCore:Notify', src, 'This video can\'t be played', 'error')
end)

-- Full snapshot for a client that just loaded in; afterwards it only receives changes.
RegisterNetEvent('Frantic_Youtube:server:RequestEmitters', function()
    local src = source
    local payload = {}
    for owner, emitter in pairs(emitters) do
        payload[tostring(owner)] = BuildEmitterPayload(emitter)
    end
    TriggerClientEvent('Frantic_Youtube:client:SetEmitters', src, payload)
end)

-- ========================
-- Volume Events
-- ========================

RegisterNetEvent('Frantic_Youtube:server:SetCitizenSpeakerVolume', function(data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    local speakerVolume = type(data) == 'table' and ToClampedNumber(data.speakerVolume, 0.0, 1.0)
    if not Player or not speakerVolume then
        return
    end

    local metadata = GetYoutubeMetadata(Player)
    metadata.SpeakerVolume = speakerVolume
    Player.Functions.SetMetaData('FranticYoutube', metadata)

    local emitter = emitters[src]
    if emitter and emitter.speakerVolume ~= speakerVolume then
        emitter.speakerVolume = speakerVolume
        BroadcastEmitter(src)
    end
end)

RegisterNetEvent('Frantic_Youtube:server:SetCitizenListenerVolume', function(data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    local listenerVolume = type(data) == 'table' and ToClampedNumber(data.listenerVolume, 0.0, 1.0)
    if not Player or not listenerVolume then
        return
    end

    local metadata = GetYoutubeMetadata(Player)
    metadata.ListenerVolume = listenerVolume
    Player.Functions.SetMetaData('FranticYoutube', metadata)
end)

-- ========================
-- Library Callbacks
-- ========================

QBCore.Functions.CreateCallback('Frantic_Youtube:server:GetCitizenVideos', function(source, cb)
    local citizenData = GetCitizenData(source)
    cb(citizenData and citizenData.videos or {})
end)

QBCore.Functions.CreateCallback('Frantic_Youtube:server:GetCitizenPlaylists', function(source, cb)
    local citizenData = GetCitizenData(source)
    cb(citizenData and citizenData.playlists or {})
end)

QBCore.Functions.CreateCallback('Frantic_Youtube:server:CreateNewPlaylist', function(source, cb, data)
    local citizenData = GetCitizenData(source)
    local name = type(data) == 'table' and type(data.name) == 'string' and data.name:match('^%s*(.-)%s*$') or ''
    if not citizenData or name == '' or #citizenData.playlists >= Config.maxPlaylists then
        cb(false)
        return
    end

    local nextId = 1
    for _, playlist in ipairs(citizenData.playlists) do
        nextId = math.max(nextId, playlist.id + 1)
    end

    citizenData.playlists[#citizenData.playlists + 1] = {
        id = nextId,
        name = name:sub(1, Config.maxPlaylistNameLength),
        videos = {},
    }
    SavePlaylists(citizenData)
    cb(citizenData.playlists)
end)

QBCore.Functions.CreateCallback('Frantic_Youtube:server:AddVideoToPlaylist', function(source, cb, data)
    local src = source
    if type(data) ~= 'table' or type(data.playlistActive) ~= 'table' then
        cb(false)
        return
    end

    local videoId = ExtractVideoId(data.url)
    local playlistId = tonumber(data.playlistActive.id)
    if not videoId or not playlistId then
        cb(false)
        return
    end

    local metadata = FetchVideoMetadata(videoId)
    local citizenData = metadata and GetCitizenData(src)
    if not citizenData then
        cb(false)
        return
    end

    for _, playlist in ipairs(citizenData.playlists) do
        if playlist.id == playlistId then
            local video = BuildVideoEntry(videoId, metadata)
            if not FindVideoIndex(playlist.videos, videoId) then
                if #playlist.videos >= Config.maxPlaylistSize then
                    cb(false)
                    return
                end
                playlist.videos[#playlist.videos + 1] = video
                SavePlaylists(citizenData)
            end
            cb(video)
            return
        end
    end

    cb(false)
end)

-- ========================
-- Cleanup
-- ========================

local function ForgetPlayer(src)
    RemoveEmitter(src)
    citizenCache[src] = nil
    lastPlayRequest[src] = nil
end

AddEventHandler('playerDropped', function()
    ForgetPlayer(source)
end)

-- Character switch: the speaker and cached library belong to the character being logged out.
-- AddEventHandler, not RegisterNetEvent: qb-core raises this locally, and a client must not be able to pass someone else's id here.
AddEventHandler('QBCore:Server:OnPlayerUnload', function(src)
    if src then
        ForgetPlayer(src)
    end
end)
