QBCore = exports['qb-core']:GetCoreObject()

function print_table(node)
    local cache, stack, output = {},{},{}
    local depth = 1
    local output_str = "{\n"

    while true do
        local size = 0
        for k,v in pairs(node) do
            size = size + 1
        end

        local cur_index = 1
        for k,v in pairs(node) do
            if (cache[node] == nil) or (cur_index >= cache[node]) then

                if (string.find(output_str,"}",output_str:len())) then
                    output_str = output_str .. ",\n"
                elseif not (string.find(output_str,"\n",output_str:len())) then
                    output_str = output_str .. "\n"
                end

                -- This is necessary for working with HUGE tables otherwise we run out of memory using concat on huge strings
                table.insert(output,output_str)
                output_str = ""

                local key
                if (type(k) == "number" or type(k) == "boolean") then
                    key = "["..tostring(k).."]"
                else
                    key = "['"..tostring(k).."']"
                end

                if (type(v) == "number" or type(v) == "boolean") then
                    output_str = output_str .. string.rep('\t',depth) .. key .. " = "..tostring(v)
                elseif (type(v) == "table") then
                    output_str = output_str .. string.rep('\t',depth) .. key .. " = {\n"
                    table.insert(stack,node)
                    table.insert(stack,v)
                    cache[node] = cur_index+1
                    break
                else
                    output_str = output_str .. string.rep('\t',depth) .. key .. " = '"..tostring(v).."'"
                end

                if (cur_index == size) then
                    output_str = output_str .. "\n" .. string.rep('\t',depth-1) .. "}"
                else
                    output_str = output_str .. ","
                end
            else
                -- close the table
                if (cur_index == size) then
                    output_str = output_str .. "\n" .. string.rep('\t',depth-1) .. "}"
                end
            end

            cur_index = cur_index + 1
        end

        if (size == 0) then
            output_str = output_str .. "\n" .. string.rep('\t',depth-1) .. "}"
        end

        if (#stack > 0) then
            node = stack[#stack]
            stack[#stack] = nil
            depth = cache[node] == nil and depth + 1 or depth - 1
        else
            break
        end
    end

    -- This is necessary for working with HUGE tables otherwise we run out of memory using concat on huge strings
    table.insert(output,output_str)
    output_str = table.concat(output)

    print(output_str)
end

function getTablelength(T)
    local count = 0
    for _ in pairs(T) do count = count + 1 end
    return count
end

local globalVideoTimer = 0 -- Serverside timer to keep track of the video time in seconds

local lastVideoData = {} -- Array to store the last video data for a citizen

-- Except source_0, all other ids are networked
local vidSourceTable = {}

CreateThread(function()
    while true do
        globalVideoTimer = globalVideoTimer + (Config.serverRefreshRate/1000)
        Wait(Config.serverRefreshRate)
        
        for k, v in pairs(vidSourceTable) do
            if vidSourceTable[k] then
                if vidSourceTable[k].videoUrl ~= "" then
                    if vidSourceTable[k].videoState == 1 then -- Playings
                        vidSourceTable[k].videoCurrentTime = vidSourceTable[k].videoCurrentTime + (Config.serverRefreshRate/1000)
                    end

                    if vidSourceTable[k].videoDuration > 0 and vidSourceTable[k].videoCurrentTime >= vidSourceTable[k].videoDuration then 
                        vidSourceTable[k].videoStartTime = 0
                        vidSourceTable[k].videoCurrentTime = vidSourceTable[k].videoDuration + 2
                        vidSourceTable[k].videoState = 0 -- Ended
                    end
                end
            end
        end

        TriggerClientEvent('Frantic_Youtube:client:UpdateVideoData', -1, vidSourceTable, globalVideoTimer)
    end
end)

QBCore.Functions.CreateCallback('Frantic_Youtube:server:PlayVideoWithID', function(source, cb, data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    local time = 0
    local citizenId = Player.PlayerData.citizenid
    local sourceId = FranticYoutube_Server_GetSourceID(src, data)

    -- Now we don't store the video data in the database. We just store the video id in the citizen's data

    MySQL.Async.fetchAll("SELECT * FROM frantic_youtube_citizens WHERE citizenid = @citizenid", {
        ["@citizenid"] = citizenId
    }, function (citizenResult)
        if citizenResult[1] == nil then
            MySQL.insert('INSERT INTO frantic_youtube_citizens (citizenid, playlists, videos) VALUES (?, ?, ?)', {
                citizenId,
                "",
                "",
            })
        end

        lastVideoData[src] = "empty"
        TriggerClientEvent('Frantic_Youtube:client:GetVideoDataFromID', src, data)

        while lastVideoData[src] == "empty" do
            Wait(100)
            time = time + 100

            if time > 5000 then -- 5 seconds, took to long. Error
                cb("timeout")
                break -- Not really needed lmao
            end
        end

        local videoTable = {
            ["url"] = lastVideoData[src]["url"],
            ["title"] = lastVideoData[src]["title"],
            ["author"] = lastVideoData[src]["author"],
            ["duration"] = lastVideoData[src]["duration"],
        }

        local videos = json.decode(citizenResult[1].videos)
        if videos == nil then
            videos = {[0] = videoTable}
        else
            -- Check if video url already exists
            for k, v in pairs(videos) do
                if v.url == videoTable.url then
                    vidSourceTable[sourceId].videoUrl = videoTable.url
                    vidSourceTable[sourceId].videoStartTime = globalVideoTimer
                    vidSourceTable[sourceId].videoCurrentTime = 0
                    vidSourceTable[sourceId].videoDuration = videoTable.duration
                    vidSourceTable[sourceId].videoState = 1
                    vidSourceTable[sourceId].videoLoaded = false
                    vidSourceTable[sourceId].videoSpeakerVolume = Player.PlayerData.metadata['FranticYoutube'].SpeakerVolume
                    cb(lastVideoData[src])
                    return
                end
            end

            videos[getTablelength(videos)] = videoTable
        end

        MySQL.Async.execute('UPDATE frantic_youtube_citizens SET videos = @videos WHERE citizenid = @citizenid', {
            ["@citizenid"] = citizenId,
            ["@videos"] = json.encode(videos)
        })
        vidSourceTable[sourceId].videoUrl = videoTable.url
        vidSourceTable[sourceId].videoStartTime = globalVideoTimer
        vidSourceTable[sourceId].videoCurrentTime = 0
        vidSourceTable[sourceId].videoDuration = videoTable.duration
        vidSourceTable[sourceId].videoState = 1
        vidSourceTable[sourceId].videoLoaded = false
        vidSourceTable[sourceId].videoSpeakerVolume = Player.PlayerData.metadata['FranticYoutube'].SpeakerVolume
        cb(lastVideoData[src])
    end)
end)

QBCore.Functions.CreateCallback('Frantic_Youtube:server:AddVideoToPlaylist', function(source, cb, data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    local time = 0
    local citizenId = Player.PlayerData.citizenid
    local emptyPlaylistTable = {
        ['name'] = data.playlistActive.name,
        ['videos'] = '',
    }

    -- Now we don't store the video data in the database. We just store the video id in the citizen's data

    MySQL.Async.fetchAll("SELECT * FROM frantic_youtube_citizens WHERE citizenid = @citizenid", {
        ["@citizenid"] = citizenId
    }, function (citizenResult)
        if citizenResult[1] == nil then
            MySQL.insert('INSERT INTO frantic_youtube_citizens (citizenid, playlists, videos) VALUES (?, ?, ?)', {
                citizenId,
                "",
                "",
            })
        end

        lastVideoData[src] = "empty"
        TriggerClientEvent('Frantic_Youtube:client:GetVideoDataFromID', src, data.url)

        while lastVideoData[src] == "empty" do
            Wait(100)
            time = time + 100

            if time > 5000 then -- 5 seconds, took to long. Error
                cb("timeout")
                break -- Not really needed lmao
            end
        end

        local videoTable = {
            ["url"] = lastVideoData[src]["url"],
            ["title"] = lastVideoData[src]["title"],
            ["author"] = lastVideoData[src]["author"],
            ["duration"] = lastVideoData[src]["duration"],
        }

        local playlists = json.decode(citizenResult[1].playlists)
        if playlists == nil then
            playlists = {[0] = emptyPlaylistTable}
        else
            -- Check if video url already exists
            for k, v in pairs(playlists) do
                if v.id == data.playlistActive.id then
                    if v.videos == nil or v.videos == '' then
                        v.videos = {[0] = videoTable}
                        break
                    else
                        for k2, v2 in pairs(v.videos) do
                            if v2.url == videoTable.url then
                                cb(lastVideoData[src])
                                return
                            end
                        end
                    end
                    v.videos[getTablelength(v.videos)] = videoTable
                    break
                end
            end
        end

        MySQL.Async.execute('UPDATE frantic_youtube_citizens SET playlists = @playlists WHERE citizenid = @citizenid', {
            ["@citizenid"] = citizenId,
            ["@playlists"] = json.encode(playlists)
        })
    end)
    cb(lastVideoData[src])
end)

-- This is a callback function to get the video data for a citizen
QBCore.Functions.CreateCallback('Frantic_Youtube:server:GetVideoData', function(source, cb, data)
    local src = source
    local time = 0
    lastVideoData[src] = "empty"

    TriggerClientEvent('Frantic_Youtube:client:GetVideoDataFromURL', src, data)

    while lastVideoData[src] == "empty" do
        Wait(100)
        time = time + 100

        if time > 5000 then -- 5 seconds, took to long. Error
            cb("timeout")
            break -- Not really needed lmao
        end
    end

    cb(lastVideoData[src])
end)

-- For internal use, to update the video data for a citizen
-- I suggest not to use this event from outside
RegisterNetEvent('Frantic_Youtube:server:UpdateVideoDataForSource', function(data)
    local src = source

    lastVideoData[src] = data
end)

function FranticYoutube_Server_GetDataOnlySourceID(source, data)
    local index = 0 -- This index is not networked. It is only used to keep track of the video data for the citizen
    local vidSourceID = source .. '_' .. index
    --if vidSourceTable[vidSourceID] then
        -- For now we only use one video source per citizen
        --
        --while vidSourceTable[vidSourceID] do
        --    index = index + 1
        --    vidSourceID = tostring(source) .. '_' .. index
        --end
        --print('Source ID already exists')
    --else
    --vidSourceTable[source][index] = {

    if not (vidSourceTable[vidSourceID]) then
        vidSourceTable[vidSourceID] = {
            source = source,
            index = index,
            videoUrl = "", --data.url,
            videoStartTime = 0,
            videoCurrentTime = 0, --data.time,
            videoDuration = 0, -- data.duration,
            videoState = 1, --data.state,
            videoVolume = 1, --data.volume,
            videoLoaded = false,
            videoSpeakerVolume = 0,
        }
    end

    return vidSourceID
end

function FranticYoutube_Server_GetSourceID(source, data)
    local index = 1
    local vidSourceID = source .. '_' .. index
    if vidSourceTable[vidSourceID] then
        -- For now we only use one video source per citizen
        --
        --while vidSourceTable[vidSourceID] do
        --    index = index + 1
        --    vidSourceID = tostring(source) .. '_' .. index
        --end
        --print('Source ID already exists')
    else
    --vidSourceTable[source][index] = {
        vidSourceTable[vidSourceID] = {
            source = source,
            index = index,
            videoUrl = data.url,
            videoStartTime = 0,
            videoCurrentTime = 0, --data.time,
            videoDuration = 0, -- data.duration,
            videoState = 1, --data.state,
            videoVolume = 1, --data.volume,
            videoLoaded = false,
            videoSpeakerVolume = 1,
        }
    end
    return vidSourceID
end

QBCore.Functions.CreateCallback('Frantic_Youtube:server:GetDataOnlySourceID', function(source, cb, data)
    cb(FranticYoutube_Server_GetDataOnlySourceID(source, data))
end)

QBCore.Functions.CreateCallback('Frantic_Youtube:server:GetSourceID', function(source, cb, data)
    cb(FranticYoutube_Server_GetSourceID(source, data))
end)


QBCore.Functions.CreateCallback('Frantic_Youtube:server:GetCitizenVideos', function(source, cb, data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    local citizenId = Player.PlayerData.citizenid
    local waitTime = 0

    MySQL.Async.fetchAll("SELECT * FROM frantic_youtube_citizens WHERE citizenid = @citizenid", {
        ["@citizenid"] = citizenId
    }, function (result)
        if result[1] == nil then
            cb("empty")
        else
            local videos = result[1].videos
            if videos == nil then
                cb("empty")
            else
                cb(json.decode(videos))
            end
        end
    end)
end)


QBCore.Functions.CreateCallback('Frantic_Youtube:server:GetCitizenPlaylists', function(source, cb, data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    local citizenId = Player.PlayerData.citizenid
    local waitTime = 0

    MySQL.Async.fetchAll("SELECT * FROM frantic_youtube_citizens WHERE citizenid = @citizenid", {
        ["@citizenid"] = citizenId
    }, function (result)
        if result[1] == nil then
            cb("empty")
        else
            local playlists = result[1].playlists
            if playlists == nil then
                cb("empty")
            else
                cb(json.decode(playlists))
            end
        end
    end)  
end)


QBCore.Functions.CreateCallback('Frantic_Youtube:server:CreateNewPlaylist', function(source, cb, data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    local citizenId = Player.PlayerData.citizenid
    local emptyPlaylistTable = {
        ['name'] = data.name,
        ['videos'] = data.videos,
        ['id'] = 0,
    }
    -- Now, we don't use the playlists table. We just store the playlist in the citizen's data
    MySQL.Async.fetchAll("SELECT * FROM frantic_youtube_citizens WHERE citizenid = @citizenid", {
        ["@citizenid"] = citizenId
    }, function (citizenResult)
        if citizenResult[1] == nil then
            MySQL.insert('INSERT INTO frantic_youtube_citizens (citizenid, playlists, videos) VALUES (?, ?, ?)', {
                citizenId,
                {[0] = emptyPlaylistTable},
                '',
            })
        else
            local playlists = json.decode(citizenResult[1].playlists)
            if playlists == nil then
                playlists = {[0] = emptyPlaylistTable}
            else
                emptyPlaylistTable['id'] = getTablelength(playlists)
                playlists[getTablelength(playlists)] = emptyPlaylistTable
            end
            MySQL.Async.execute('UPDATE frantic_youtube_citizens SET playlists = @playlists WHERE citizenid = @citizenid', {
                ["@citizenid"] = citizenId,
                ["@playlists"] = json.encode(playlists),
            })
        end
    end)
end)

RegisterNetEvent('Frantic_Youtube:server:SetVideoPlayingStatus', function(data)
    local src = source
    local sourceId = FranticYoutube_Server_GetSourceID(src, {url = ""})

    vidSourceTable[sourceId].videoState = data.state
end)

RegisterNetEvent('Frantic_Youtube:server:SetVideoTime', function(data)
    local src = source
    local sourceId = FranticYoutube_Server_GetSourceID(src, {url = ""})

    vidSourceTable[sourceId].videoCurrentTime = tonumber(data.time)
end)

RegisterNetEvent('Frantic_Youtube:server:SetVideoLoadedForSource', function(data)
    local src = source
    --local sourceId = FranticYoutube_Server_GetSourceID(src, {url = "dQw4w9WgXcQ"}) -- Never gonna give you up
    if (string.match(data.vidSrcID, "([^_]+)")) then -- Source is the owner
        vidSourceTable[data.vidSrcID].videoLoaded = data.vidLoaded
        if data.vidLoaded then
            vidSourceTable[data.vidSrcID].videoCurrentTime = 0 -- Start video when it's loaded
        end
        --TriggerClientEvent('Frantic_Youtube:client:SetVideoLoadedForSource', src, data.vidSrcID, data.vidLoaded)
    end
end)

RegisterNetEvent('Frantic_Youtube:server:SetCitizenSpeakerVolume', function(data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    local citizenId = Player.PlayerData.citizenid

    Player.PlayerData.metadata['FranticYoutube'].SpeakerVolume = data.speakerVolume
    Player.Functions.SetMetaData('FranticYoutube', Player.PlayerData.metadata['FranticYoutube'])

    if vidSourceTable[src .. "_1"] then
        vidSourceTable[src .. "_1"].videoSpeakerVolume = data.speakerVolume
    end

    --MySQL.Async.execute('UPDATE frantic_youtube_citizens SET speakerVolume = @speakerVolume WHERE citizenid = @citizenid', {
    --    ["@citizenid"] = citizenId,
    --    ["@speakerVolume"] = data.speakerVolume
    --})
end)

RegisterNetEvent('Frantic_Youtube:server:SetCitizenListenerVolume', function(data)
    local src = source
    local Player = QBCore.Functions.GetPlayer(src)
    local citizenId = Player.PlayerData.citizenid

    Player.PlayerData.metadata['FranticYoutube'].ListenerVolume = data.listenerVolume
    Player.Functions.SetMetaData('FranticYoutube', Player.PlayerData.metadata['FranticYoutube'])

    --MySQL.Async.execute('UPDATE frantic_youtube_citizens SET listenerVolume = @listenerVolume WHERE citizenid = @citizenid', {
    --    ["@citizenid"] = citizenId,
    --    ["@listenerVolume"] = data.listenerVolume
    --})
end)


function NullifySourceID(sourceID)
    if vidSourceTable[sourceID] then
        vidSourceTable[sourceId] = nil
    end
end

AddEventHandler('playerDropped', function(reason)
    local src = source

    NullifySourceID(src .. "_0")
    NullifySourceID(src .. "_1")
end)