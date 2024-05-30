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

function extractYouTubeVideoID(url)
    local possibleMatches = {
        '[?&]v=([a-zA-Z0-9_-]+)', -- Normal
        'youtu.be/([a-zA-Z0-9_-]+)', -- Shortened
        'embed/([a-zA-Z0-9_-]+)', -- Embed
        'shorts/([a-zA-Z0-9_-]+)', -- Shorts
    }

    local match = nil

    for _, pattern in ipairs(possibleMatches) do
        match = string.match(url, pattern)
        if match then
            return match
        end
    end
end

RegisterCommand('playvideo', function(source, args)
    if not args[1] then
        QBCore.Functions.Notify('You need to input a Video ID', 'error')
    else
        TriggerEvent('Frantic_Youtube:client:PlayVideoWithURL', args[1])
    end
end, false)

-- Clientside callable events. This will only affect the client. Not networked.
RegisterNetEvent('Frantic_Youtube:client:PlayVideoWithData', function(videoData)
    QBCore.Functions.TriggerCallback('Frantic_Youtube:server:GetSourceID', function(vidSourceID)
        SendNUIMessage({
            action = 'PlayVideoWithID',
            videoID = videoData["url"],
            vidSourceID = vidSourceID,
        })
    end, videoData)
end)

--[[
RegisterNetEvent('Frantic_Youtube:client:PlayVideoWithURL', function(videoURL)
    QBCore.Functions.TriggerCallback('Frantic_Youtube:server:GetSourceID', function(vidSourceID)
        SendNUIMessage({
            action = 'PlayVideoWithID',
            videoID = extractYouTubeVideoID(videoURL),
            vidSourceID = vidSourceID,
        })
    end, videoURL)
end)

RegisterNetEvent('Frantic_Youtube:client:PlayVideoWithID', function(videoID)
    QBCore.Functions.TriggerCallback('Frantic_Youtube:server:GetSourceID', function(vidSourceID)
        SendNUIMessage({
            action = 'PlayVideoWithID',
            videoID = videoID,
            vidSourceID = vidSourceID,
        })
    end, videoID)
end)
]]--

-- Clientside callable events end.

local sourcePlayer = 0
local sourcePlayerPed = 0
local sourcePlayerCoords = vector3(0,0,0)
local sourcePlayerDistance = 0
local sendCurrentData = false
local lastSourceTable = nil
local clientRefreshRate <const> = 100 -- 100ms

-- This is omittable.
-- Mainly for smoothness of the attenuation of the sound.
CreateThread(function()
    while true do
        Wait(clientRefreshRate)
        RefreshPlayers()
    end
end)

--[[
CreateThread(function()
    -- Do Once
    local Player = QBCore.Functions.GetPlayerData()
end)
]]--

local RefreshPlayerMetadata = nil

function RefreshPlayers()
    if not lastSourceTable then
        return
    end

    RefreshPlayerMetadata = QBCore.Functions.GetPlayerData().metadata

    if (RefreshPlayerMetadata == nil) then
        RefreshPlayerMetadata = { ListenerVolume = 1.0 }
    else
        RefreshPlayerMetadata = RefreshPlayerMetadata['FranticYoutube']
    end

    for vidSourceID, videoData in pairs(lastSourceTable) do
        sendCurrentData = false
        --if (string.sub(vidSourceID, -1) == '0') then
        if (videoData.index == 0) then
            -- This source is data only, we don't need to play it
        else
            -- Get entity coords from source id (sourceid is the owner player's server id)
            -- We'll get distance between current client and the source player
            sourcePlayer = GetPlayerFromServerId(videoData.source)
            sourcePlayerPed = GetPlayerPed(sourcePlayer)
            sourcePlayerCoords = GetEntityCoords(sourcePlayerPed)
            sourcePlayerDistance = #(GetEntityCoords(PlayerPedId()) - sourcePlayerCoords)

            if (videoData.videoSpeakerVolume == nil) then
                videoData.videoSpeakerVolume = 1.0
            end

            if (sourcePlayerDistance < 0.2) then
                -- Too close to player, can be player's own source
                -- Play at full volume
                
                videoData.videoVolume = 100.0 * videoData.videoSpeakerVolume * RefreshPlayerMetadata.ListenerVolume
                
                sendCurrentData = true
            elseif (sourcePlayerDistance < Config.voiceModes[3][1]) then
                videoData.videoVolume = 1 - (sourcePlayerDistance / Config.voiceModes[3][1])
                videoData.videoVolume = (videoData.videoVolume * 100.0) * videoData.videoSpeakerVolume * RefreshPlayerMetadata.ListenerVolume

                sendCurrentData = true
            else
                -- Too far from player, don't play
                videoData.videoVolume = 0.0
                sendCurrentData = true
            end

            if sendCurrentData then
                SendNUIMessage({
                    action = 'UpdateVideoData',
                    videoData = videoData,
                    videoSourceID = vidSourceID,
                })
            end
        end
    end

    TriggerEvent('Frantic_Youtube:client:UpdateVideoDataResource', lastSourceTable, vidServerTime)
end

-- This is for other resources to use the video data
-- Add your own event handler to get the video data
RegisterNetEvent('Frantic_Youtube:client:UpdateVideoDataResource')

RegisterNetEvent('Frantic_Youtube:client:UpdateVideoData', function(vidSourceTable, vidServerTime)
    if not vidSourceTable then
        -- Video update error
        lastSourceTable = nil
    else
        lastSourceTable = vidSourceTable
        RefreshPlayers()
    end
end)

RegisterNetEvent('Frantic_Youtube:client:GetVideoDataFromURL', function(videoURL)
    QBCore.Functions.TriggerCallback('Frantic_Youtube:server:GetDataOnlySourceID', function(vidSourceID)
        SendNUIMessage({
            action = 'GetVideoDataFromID',
            videoID = extractYouTubeVideoID(videoURL),
            vidSourceID = vidSourceID,
        })
    end, videoURL)
end)

RegisterNetEvent('Frantic_Youtube:client:GetVideoDataFromID', function(videoID)
    QBCore.Functions.TriggerCallback('Frantic_Youtube:server:GetDataOnlySourceID', function(vidSourceID)
        SendNUIMessage({
            action = 'GetVideoDataFromID',
            videoID = videoID,
            vidSourceID = vidSourceID,
        })
    end, videoURL)
end)

RegisterNUICallback('ReceiveVideoData', function(data, cb)
    TriggerServerEvent('Frantic_Youtube:server:UpdateVideoDataForSource', data)
    cb('ok')
end)

RegisterNUICallback('SetVideoLoaded', function(data, cb)
    TriggerServerEvent('Frantic_Youtube:server:SetVideoLoadedForSource', data)
    cb('ok')
end)

