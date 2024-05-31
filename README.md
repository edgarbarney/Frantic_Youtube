# Frantic's Youtube Player Library for QBCore

This is a library for playing YouTube videos as sounds in the background in FiveM's QBCore Framework.  

Because it doesn't download or stream anything, it complies with YouTube ToS. It's built completely upon YouTube's API.

It's not yet perfect, but hopefully it will be useful for other people.

This is not a standalone asset; as stated, it's a 'library' for other assets to use.

Credit to <b>FranticDreamer</b> is not required, but hugely appreciated.

Feel free to create issues and pull requests. If you fix a bug, don't keep it to your server only. Share with people with a pull request, please.

## General Information
Videos are networked, attached to players and listenable by everyone in a certain radius.  
Radius is in the config.lua  
  
Default settings:  
Server updates clients every second.  
Client updates videos every 10th of a second.  


## Installation
Try one of the working methods below
### Older QBCore
1. Download the [Latest Release](https://github.com/edgarbarney/Frantic_Youtube/releases).
2. Extract content into somewhere convenient in the resources folder.
3. (Optional) Put `ensure Frantic_Youtube` into the server.cfg.
4. Navigate to your qb-core's player.lua script. Generally, it's location is    
`resources\[qb]\qb-core\server\player.lua`.
5. Find the `QBCore.Player.CheckPlayerData` function, located around 100th line, you can search for   
`function QBCore.Player.CheckPlayerData(source, PlayerData)`.
6. Find the `--Metadata` part.  
If you can't find it and there's `metadata = {` instead, try continuing with the Newer QBCore installation.
7. Then add thid code in an appropriate place, preferably right before the `-- Job` part:
```lua
PlayerData.metadata['FranticYoutube'] = PlayerData.metadata['FranticYoutube'] or {
	ListenerVolume = 1.0,
	SpeakerVolume = 1.0,
}
```
8. Finally, run the SQL file for your database.

### Newer QBCore
1. Download the [Latest Release](https://github.com/edgarbarney/Frantic_Youtube/releases).
2. Extract content into somewhere convenient in the resources folder.
3. (Optional) Put `ensure Frantic_Youtube` into the server.cfg.
4. Navigate to your qb-core's config.lua file. Generally, it's location is   
`resources\[qb]\qb-core\config.lua`.
5. Find the `QBConfig.Player.PlayerDefaults` table, .located around 20th line.
6. Find the `metadata = {` part.
7. Then add thid code in an appropriate place, preferably right after the `phonedata = {}` part:
```lua
FranticYoutube = {
	ListenerVolume = 1.0,
	SpeakerVolume = 1.0,
}
```
8. Finally, run the SQL file for your database.

## Usage - Callbacks and Events
1. <b>Server Callback</b> - Add new video to a playlist:  
	`'Frantic_Youtube:server:AddVideoToPlaylist'`

	Adds a new ID to a given playlist for the source client

	<b>Example arguments to Pass:</b>
	```lua
	data = {
		url = 'dQw4w9WgXcQ', 	-- YouTube Video ID
		playlistActive = {
			id = 0, 			-- Target Playlist ID
		},		
	}
	```
	<b>Returns:</b> Video data of the newly added track.
2. <b>Server Event</b> - Set Video Playing Status:  
	`'Frantic_Youtube:server:SetVideoPlayingStatus'` 

	Sets the source client's video playback status.

	<b>Example arguments to Pass:</b>
	```lua
	data = {
		state = 1,
			 -- 1 = Play.
			 -- 2 = Pause.
			 -- 0 = End (Stop).
	}
	```

3. <b>Server Event</b> - Set Video Time:  
	`'Frantic_Youtube:server:SetVideoTime'` 

	Sets the source client's video time to the argument.

	<b>Example arguments to Pass:</b>
	```lua
	data = {
		time = 115, -- Time in seconds.
	}
	```

4. <b>Server Event</b> - Set Speaker Volume:  
	`'Frantic_Youtube:server:SetCitizenSpeakerVolume'` 

	Sets the source client's speaker volume. This will change the source client's video volume for everyone.

	<b>Example arguments to Pass:</b>
	```lua
	data = {
		speakerVolume = 1.0,
		-- Between 0.0 and 1.0.
		-- 0.0 = Silent.
		-- 1.0 = Full volume.
	}
	```

5. <b>Server Event</b> - Set Listener Volume:  
	`'Frantic_Youtube:server:SetCitizenListenerVolume'` 

	Sets the source client's listener volume. This will change the source client's listening volume for every video source.

	<b>Example arguments to Pass:</b>
	```lua
	data = {
		listenerVolume = 1.0,
		-- Between 0.0 and 1.0.
		-- 0.0 = Silent.
		-- 1.0 = Full volume.
	}
	```

6. <b>Server Callback</b> - Create New Playlist:  
	`'Frantic_Youtube:server:CreateNewPlaylist'` 

	Creates a new playlist for the source client.

	<b>Example arguments to Pass:</b>
	```lua
	data = {
		name = 'New Playlist',  -- Name of the playlist that will be created.
		videos = '', -- Initial video data. I suggest leaving it empty and using AddVideoToPlaylist afterwards.
	}
	```
	<b>Returns:</b> Nothing. (TODO: Should return new playlist ID)

7. <b>Server Callback</b> - Play Video with ID:  
	`'Frantic_Youtube:server:PlayVideoWithID'` 

	Plays a video for the source client and adds it to the video history.

	<b>Example arguments to Pass:</b>
	```lua
	data = {
		url = 'dQw4w9WgXcQ',  -- YouTube ID of the video to play
	}
	```
	<b>Returns:</b> Video Data OR "timeout"

8. <b>Server Callback</b> - Get Citizen Videos:  
	`'Frantic_Youtube:server:GetCitizenVideos'` 

	Used for retrieving source client's video history. 

	<b>Example arguments to Pass:</b>
	```lua
	No arguments
	```
	<b>Returns:</b> A list of client's played videos.

9. <b>Server Callback</b> - Get Citizen Playlists:  
	`'Frantic_Youtube:server:GetCitizenPlaylists'` 

	Used for retrieving source client's playlists. 

	<b>Example arguments to Pass:</b>
	```lua
	No arguments
	```
	<b>Returns:</b> A list of client's playlists.

9. <b>Client Event Handler</b> - Update Video Data (For your Resource):  
	`'Frantic_Youtube:client:UpdateVideoDataResource'` 

	You can use this with AddEventHandler to do stuff with updated song data.

	This is called every time after server updates the song data for clients.

	<b>Example arguments that will be given in order:</b>
	```lua
	sourceTable = { -- Table of sources with player IDs
		"25_1" = { -- An example source with player ID of 25
	            source = 25,		-- Owner Client ID
	            index = 1,			-- For now, we use only 1
	            videoUrl = 'dQw4w9WgXcQ',	-- Youtube ID of Current Video
	            videoStartTime = 124,	-- Start Time (in Server Sync Time) 
	            videoCurrentTime = 152,	-- Current Video Time
	            videoDuration = 220,	-- Current Video Total Duration
	            videoState = 1,		-- Current Video State
	            videoVolume = 1,		-- Current Video Volume
	            videoLoaded = false,	-- Is Video Finished Buffering?
	            videoSpeakerVolume = 1,	-- Speaker Volume of the Owner Client
		}
	}, 
	vidServerTime = 100 -- Server sync time
	```

