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
-- HTTP
-- ========================

local function UrlEncode(text)
    return (text:gsub('[^%w%-_%.~]', function(character)
        return ('%%%02X'):format(character:byte())
    end))
end

-- Data API titles arrive HTML-escaped ("Don&#39;t Stop").
local function DecodeHtmlEntities(text)
    return (text:gsub('&#(%d+);', function(code)
        return utf8.char(tonumber(code))
    end):gsub('&quot;', '"'):gsub('&lt;', '<'):gsub('&gt;', '>'):gsub('&amp;', '&'))
end

-- Awaitable GET. Resolves with status 0 on timeout, since PerformHttpRequest has none of its own.
local function HttpGet(url, headers)
    local p = promise.new()
    local settled = false
    local function Settle(status, body)
        if not settled then
            settled = true
            p:resolve({ status = status, body = body })
        end
    end

    PerformHttpRequest(url, function(status, body)
        Settle(status, body)
    end, 'GET', '', headers or {})

    SetTimeout(Config.metadataTimeout, function()
        Settle(0, nil)
    end)

    return Citizen.Await(p)
end

local function DecodeJsonBody(response)
    if response.status ~= 200 or type(response.body) ~= 'string' then
        return nil
    end

    local ok, data = pcall(json.decode, response.body)
    if not ok or type(data) ~= 'table' then
        return nil
    end
    return data
end

-- ========================
-- Video Metadata
-- ========================

local function CleanAuthor(author)
    return ((type(author) == 'string' and author or ''):gsub(' %- Topic$', '')):sub(1, 100)
end

-- embeddable is only true when oEmbed or the Data API's embeddable filter vouched for the video.
-- Results scraped from the search page aren't checked, so playing one still goes through oEmbed once.
local function RememberMetadata(videoId, title, author, duration, embeddable)
    local cached = metadataCache[videoId]
    if not cached then
        if metadataCacheSize >= maxMetadataCacheSize then
            metadataCache = {}
            metadataCacheSize = 0
        end
        metadataCacheSize = metadataCacheSize + 1
        cached = { duration = 0, embeddable = false }
        metadataCache[videoId] = cached
    end

    cached.title = title:sub(1, 200)
    cached.author = CleanAuthor(author)
    if duration and duration > 0 then
        cached.duration = duration
    end
    cached.embeddable = cached.embeddable or embeddable
    return cached
end

-- Title and author come from YouTube on the server, never from a client, so a modded client can't store arbitrary text in someone's library.
-- oEmbed also refuses videos that can't be embedded, which the iframe player couldn't play anyway.
local function FetchVideoMetadata(videoId)
    local cached = metadataCache[videoId]
    if cached and cached.embeddable then
        return cached
    end

    local response = HttpGet('https://www.youtube.com/oembed?format=json&url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3D' .. videoId)
    local data = DecodeJsonBody(response)
    if not data or type(data.title) ~= 'string' then
        -- 401 = embedding disabled, 404 = private/removed, 0 = timed out
        DebugPrint('oEmbed refused %s (HTTP %s)', videoId, response.status)
        return nil
    end

    return RememberMetadata(videoId, data.title, data.author_name, 0, true)
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
-- Search
-- ========================

local searchCache = {} -- [lowercase query] = { results, expiresAt }
local lastSearchRequest = {}

-- "1:02:03" -> 3723
local function ParseClockDuration(text)
    if type(text) ~= 'string' then
        return 0
    end

    local total = 0
    for part in text:gmatch('%d+') do
        total = total * 60 + tonumber(part)
    end
    return total
end

-- "P1DT2H3M4S" -> seconds. Only the part after T holds hours/minutes/seconds; an M before it would be months.
local function ParseIsoDuration(text)
    if type(text) ~= 'string' then
        return 0
    end

    local days = tonumber(text:match('P(%d+)D')) or 0
    local timePart = text:match('T(.*)$') or ''
    local hours = tonumber(timePart:match('(%d+)H')) or 0
    local minutes = tonumber(timePart:match('(%d+)M')) or 0
    local seconds = tonumber(timePart:match('(%d+)S')) or 0
    return ((days * 24 + hours) * 60 + minutes) * 60 + seconds
end

local function RunsText(node)
    if type(node) ~= 'table' then
        return nil
    end
    if type(node.simpleText) == 'string' then
        return node.simpleText
    end
    if type(node.runs) == 'table' and type(node.runs[1]) == 'table' then
        return node.runs[1].text
    end
    return nil
end

-- Finds videoRenderer entries anywhere in ytInitialData, in page order, rather than following one exact path that YouTube reshuffles every few months.
local function CollectVideoRenderers(node, results, count, depth)
    if #results >= count or depth > 40 or type(node) ~= 'table' then
        return
    end

    local renderer = node.videoRenderer
    if type(renderer) == 'table' and type(renderer.videoId) == 'string' then
        results[#results + 1] = renderer
        return
    end

    if #node > 0 then
        for _, child in ipairs(node) do
            CollectVideoRenderers(child, results, count, depth + 1)
        end
    else
        for _, child in pairs(node) do
            CollectVideoRenderers(child, results, count, depth + 1)
        end
    end
end

local function SearchByScraping(query, count)
    -- sp=EgIQAQ%3D%3D is YouTube's "Videos only" filter. The consent cookies skip the EU cookie wall, which would otherwise be returned instead of results.
    local response = HttpGet('https://www.youtube.com/results?hl=en&gl=US&sp=EgIQAQ%3D%3D&search_query=' .. UrlEncode(query), {
        ['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
        ['Accept-Language'] = 'en-US,en;q=0.9',
        ['Cookie'] = 'SOCS=CAI; CONSENT=YES+1',
    })

    if response.status ~= 200 or type(response.body) ~= 'string' then
        DebugPrint('Search page request failed (HTTP %s)', response.status)
        return nil
    end

    local jsonText = response.body:match('var ytInitialData%s*=%s*(.-);%s*</script>') or response.body:match('window%["ytInitialData"%]%s*=%s*(.-);%s*</script>')
    if not jsonText then
        DebugPrint('Search page had no ytInitialData (%d bytes). YouTube may have changed the page or shown a consent screen.', #response.body)
        return nil
    end

    local ok, data = pcall(json.decode, jsonText)
    if not ok or type(data) ~= 'table' then
        DebugPrint('Search page ytInitialData failed to parse: %s', tostring(data))
        return nil
    end

    local renderers = {}
    CollectVideoRenderers(data, renderers, count, 0)

    local results = {}
    for _, renderer in ipairs(renderers) do
        local videoId = renderer.videoId
        local title = RunsText(renderer.title)
        if #videoId == 11 and title then
            local metadata = RememberMetadata(videoId, title, RunsText(renderer.ownerText) or RunsText(renderer.longBylineText), ParseClockDuration(RunsText(renderer.lengthText)), false)
            results[#results + 1] = BuildVideoEntry(videoId, metadata)
        end
    end
    return results
end

local function SearchWithApi(query, count, apiKey)
    local search = DecodeJsonBody(HttpGet(('https://www.googleapis.com/youtube/v3/search?part=snippet&type=video&videoEmbeddable=true&maxResults=%d&q=%s&key=%s'):format(count, UrlEncode(query), UrlEncode(apiKey))))
    if not search or type(search.items) ~= 'table' then
        DebugPrint('Data API search failed; falling back to the search page. Check the key and its quota.')
        return nil
    end

    local ids = {}
    local snippets = {}
    for _, item in ipairs(search.items) do
        local videoId = type(item.id) == 'table' and item.id.videoId
        if type(videoId) == 'string' and type(item.snippet) == 'table' then
            ids[#ids + 1] = videoId
            snippets[videoId] = item.snippet
        end
    end

    -- search.list has no durations; one videos.list call fetches all of them.
    local durations = {}
    if #ids > 0 then
        local details = DecodeJsonBody(HttpGet(('https://www.googleapis.com/youtube/v3/videos?part=contentDetails&id=%s&key=%s'):format(table.concat(ids, ','), UrlEncode(apiKey))))
        for _, item in ipairs(details and details.items or {}) do
            if type(item.contentDetails) == 'table' then
                durations[item.id] = ParseIsoDuration(item.contentDetails.duration)
            end
        end
    end

    local results = {}
    for _, videoId in ipairs(ids) do
        local snippet = snippets[videoId]
        local metadata = RememberMetadata(videoId, DecodeHtmlEntities(snippet.title or ''), DecodeHtmlEntities(snippet.channelTitle or ''), durations[videoId] or 0, true)
        results[#results + 1] = BuildVideoEntry(videoId, metadata)
    end
    return results
end

-- A pasted URL or ID resolves to that one video; anything else is a keyword search.
local function SearchVideos(query)
    local videoId = ExtractVideoId(query)
    if videoId then
        local metadata = FetchVideoMetadata(videoId)
        if metadata then
            return { BuildVideoEntry(videoId, metadata) }, 'url'
        end
        -- An 11 character keyword can look like an ID; search for it instead.
    end

    if Config.searchMode == 'single' then
        -- An empty list rather than a failure: the search worked, there's just nothing a link-only search can find.
        DebugPrint('Keyword search is off (Config.searchMode = \'single\'); only playable YouTube links and IDs are accepted')
        return {}, 'single'
    end

    local count = math.max(1, math.min(20, Config.searchResultCount))
    local apiKey = GetConvar('frantic_youtube_api_key', '')
    if apiKey ~= '' then
        local results = SearchWithApi(query, count, apiKey)
        if results then
            return results, 'api'
        end
    end

    return SearchByScraping(query, count), 'page'
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
    if emitter then
        DebugPrint('Speaker %s -> state %s, video %s, position %.1f/%.1f, speaker volume %.2f, loaded %s', src, emitter.state, emitter.videoId, GetEmitterPosition(emitter), emitter.duration, emitter.speakerVolume, tostring(emitter.loaded))
    else
        DebugPrint('Speaker %s removed', src)
    end
    TriggerClientEvent('Frantic_Youtube:client:SetEmitter', -1, src, emitter and BuildEmitterPayload(emitter) or nil)
end

local function Who(src)
    return ('%s [%s]'):format(GetPlayerName(src) or '?', src)
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
                DebugPrint('%s: %s reached its end', Who(src), emitter.videoId)
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

-- Returns up to Config.searchResultCount videos ({ url, title, author, duration }), or false.
QBCore.Functions.CreateCallback('Frantic_Youtube:server:SearchVideos', function(source, cb, query)
    local src = source
    query = type(query) == 'string' and query:match('^%s*(.-)%s*$') or ''
    DebugPrint('%s searched for "%s"', Who(src), query)

    if query == '' or #query > 200 then
        DebugPrint('Search rejected: empty or longer than 200 characters')
        cb(false)
        return
    end

    local now = GetGameTimer()
    if lastSearchRequest[src] and now - lastSearchRequest[src] < Config.searchCooldown then
        DebugPrint('Search rejected: %s is searching faster than Config.searchCooldown', Who(src))
        cb(false)
        return
    end
    lastSearchRequest[src] = now

    local cacheKey = query:lower()
    local cached = searchCache[cacheKey]
    if cached and cached.expiresAt > os.time() then
        DebugPrint('Search "%s": %d cached results', query, #cached.results)
        cb(cached.results)
        return
    end

    local results, method = SearchVideos(query)
    if not results then
        DebugPrint('Search "%s" failed (method: %s)', query, method)
        cb(false)
        return
    end

    DebugPrint('Search "%s": %d results via %s', query, #results, method)
    for index, video in ipairs(results) do
        DebugPrint('  %d. %s | %s | %s | %ss', index, video.url, video.title, video.author, video.duration)
    end

    -- Expired entries are dropped whenever a new one is stored, which keeps the cache bounded by recent searches.
    for key, entry in pairs(searchCache) do
        if entry.expiresAt <= os.time() then
            searchCache[key] = nil
        end
    end
    if #results > 0 then
        searchCache[cacheKey] = { results = results, expiresAt = os.time() + Config.searchCacheLifetime }
    end

    cb(results)
end)

QBCore.Functions.CreateCallback('Frantic_Youtube:server:PlayVideoWithID', function(source, cb, data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    local input = type(data) == 'table' and data.url or data
    local videoId = ExtractVideoId(input)
    DebugPrint('%s asked to play %s', Who(src), tostring(input))

    if not Player or not videoId then
        DebugPrint('Play rejected: %s', not Player and 'player not loaded' or 'not a YouTube URL or ID')
        cb(false)
        return
    end

    local now = GetGameTimer()
    if lastPlayRequest[src] and now - lastPlayRequest[src] < Config.playCooldown then
        DebugPrint('Play rejected: %s is pressing play faster than Config.playCooldown', Who(src))
        cb(false)
        return
    end
    lastPlayRequest[src] = now

    local metadata = FetchVideoMetadata(videoId)
    if not metadata or not QBCore.Functions.GetPlayer(src) then
        DebugPrint('Play rejected: %s', metadata and 'player left while loading' or ('YouTube won\'t embed ' .. videoId))
        cb(false)
        return
    end

    DebugPrint('%s plays %s "%s" by %s', Who(src), videoId, metadata.title, metadata.author)

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
    DebugPrint('%s set playing status to %s (1 = play, 2 = pause, 0 = stop)', Who(src), tostring(state))

    if not emitter or (state ~= stateStopped and state ~= statePlaying and state ~= statePaused) or state == emitter.state then
        DebugPrint('Status ignored: %s', not emitter and 'no speaker yet' or (state == emitter.state and 'already in that state' or 'invalid state'))
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
    DebugPrint('%s seeks to %s', Who(src), type(data) == 'table' and tostring(data.time) or '?')

    if not emitter or type(data) ~= 'table' then
        DebugPrint('Seek ignored: no speaker')
        return
    end

    local maxPosition = emitter.duration > 0 and emitter.duration or Config.maxVideoDuration
    local position = ToClampedNumber(data.time, 0.0, maxPosition)
    if not position then
        DebugPrint('Seek ignored: not a number')
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

    DebugPrint('%s: their player started %s (reported duration %s)', Who(src), emitter.videoId, tostring(data.duration))
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

    -- 2 = bad id, 5 = HTML5 player error, 100 = removed/private, 101/150 = owner disabled embedding
    DebugPrint('%s: their player refused %s with YouTube error %s', Who(src), emitter.videoId, tostring(data.code))
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
    DebugPrint('%s requested the speaker snapshot', Who(src))
    TriggerClientEvent('Frantic_Youtube:client:SetEmitters', src, payload)
end)

-- ========================
-- Volume Events
-- ========================

RegisterNetEvent('Frantic_Youtube:server:SetCitizenSpeakerVolume', function(data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    local speakerVolume = type(data) == 'table' and ToClampedNumber(data.speakerVolume, 0.0, 1.0)
    DebugPrint('%s set speaker volume to %s', Who(src), tostring(speakerVolume))
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
    DebugPrint('%s set listener volume to %s', Who(src), tostring(listenerVolume))
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
    DebugPrint('%s loaded their history: %s', Who(source), citizenData and (#citizenData.videos .. ' videos') or 'no data (player not loaded or database error)')
    cb(citizenData and citizenData.videos or {})
end)

QBCore.Functions.CreateCallback('Frantic_Youtube:server:GetCitizenPlaylists', function(source, cb)
    local citizenData = GetCitizenData(source)
    DebugPrint('%s loaded their playlists: %s', Who(source), citizenData and (#citizenData.playlists .. ' playlists') or 'no data (player not loaded or database error)')
    cb(citizenData and citizenData.playlists or {})
end)

QBCore.Functions.CreateCallback('Frantic_Youtube:server:CreateNewPlaylist', function(source, cb, data)
    local citizenData = GetCitizenData(source)
    local name = type(data) == 'table' and type(data.name) == 'string' and data.name:match('^%s*(.-)%s*$') or ''
    DebugPrint('%s creates playlist "%s"', Who(source), name)

    if not citizenData or name == '' or #citizenData.playlists >= Config.maxPlaylists then
        DebugPrint('Playlist rejected: %s', not citizenData and 'no data' or (name == '' and 'empty name' or 'Config.maxPlaylists reached'))
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
    DebugPrint('%s adds %s to playlist %s', Who(src), tostring(data.url), tostring(data.playlistActive.id))

    if not videoId or not playlistId then
        DebugPrint('Add rejected: %s', not videoId and 'not a YouTube URL or ID' or 'no playlist id')
        cb(false)
        return
    end

    local metadata = FetchVideoMetadata(videoId)
    local citizenData = metadata and GetCitizenData(src)
    if not citizenData then
        DebugPrint('Add rejected: %s', metadata and 'no data' or ('YouTube won\'t embed ' .. videoId))
        cb(false)
        return
    end

    for _, playlist in ipairs(citizenData.playlists) do
        if playlist.id == playlistId then
            local video = BuildVideoEntry(videoId, metadata)
            if not FindVideoIndex(playlist.videos, videoId) then
                if #playlist.videos >= Config.maxPlaylistSize then
                    DebugPrint('Add rejected: playlist "%s" is full', playlist.name)
                    cb(false)
                    return
                end
                playlist.videos[#playlist.videos + 1] = video
                SavePlaylists(citizenData)
                DebugPrint('Added "%s" to playlist "%s" (%d videos)', video.title, playlist.name, #playlist.videos)
            else
                DebugPrint('"%s" is already in playlist "%s"', video.title, playlist.name)
            end
            cb(video)
            return
        end
    end

    DebugPrint('Add rejected: %s has no playlist with id %s', Who(src), playlistId)
    cb(false)
end)

-- ========================
-- Cleanup
-- ========================

local function ForgetPlayer(src)
    RemoveEmitter(src)
    citizenCache[src] = nil
    lastPlayRequest[src] = nil
    lastSearchRequest[src] = nil
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
