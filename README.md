# Frantic's Youtube Player Library for QBCore

This is a library for playing YouTube videos as sounds in the background in FiveM's QBCore Framework.  

Because it doesn't download or stream anything, it complies with YouTube ToS. It's built completely upon YouTube's API.

It's not yet perfect, but hopefully, it will be useful for people.

This is not a standalone asset; as stated, it's a 'library' for being used by other assets.

Credit to <b>FranticDreamer</b> is not required, but hugely appreciated. However, keep the LICENSE.md in your source code folder and don't delete it.

Feel free to create issues and pull requests. If you fix a bug, don't keep it on your server. Share with people with a pull request, please.

## General Information
Videos are networked, attached to players and listenable by everyone in a certain radius.  
Radius is in the config.lua  

How it stays light:  
- The server only keeps a speaker for a player while they have a video, and only sends clients a message when something changes (play, pause, seek, volume, end). There is no per-second broadcast.  
- Playback position is sent as "position at the moment of sending"; every client extrapolates it with its own clock.  
- Each client keeps a small pool of YouTube players (`Config.maxActivePlayers`, 3 by default) and gives them to the nearest speakers. Everything else is not loaded at all, so 64 players on the server still means at most 3 YouTube iframes per client, and none when no one is playing music nearby. Unused players are destroyed after `Config.idlePlayerLifetime` seconds.  
- Video titles and authors come from YouTube's oEmbed endpoint on the server. The duration is reported by the owner's own player once it starts.  

## Debugging
`Config.debug = true` prints searches, plays, pauses, seeks, volume changes, speaker updates and the YouTube player pool (which player loads what, state changes, YouTube error codes) to the server console and the F8 console.  
The YouTube page's own log lines are forwarded to F8 too, prefixed with `[page]`.

## Dependencies
This library depends on:  
[oxmysql by Overextended](https://github.com/overextended/oxmysql)

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
	ListenerVolume = 0.5,
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
	ListenerVolume = 0.5,
	SpeakerVolume = 1.0,
}
```
8. Finally, run the SQL file for your database.

### Upgrading an existing database
Run the commented migration at the bottom of `frantic_youtube.sql` once. It widens the JSON columns and makes `citizenid` unique.  
Old lists stored with a `[0]` first index are converted to plain arrays automatically the next time each citizen's data is saved.

## Usage - Callbacks and Events
1. <b>Server Callback</b> - Add new video to a playlist:  
	`'Frantic_Youtube:server:AddVideoToPlaylist'`

	Adds a new ID to a given playlist for the source client

	<b>Example arguments to Pass:</b>
	```lua
	data = {
		url = 'dQw4w9WgXcQ', 	-- YouTube Video ID or URL
		playlistActive = {
			id = 1, 			-- Target Playlist ID
		},		
	}
	```
	<b>Returns:</b> Video data of the added track, or `false` if the video or playlist doesn't exist or the playlist is full.
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
	}
	```
	New playlists start empty; use AddVideoToPlaylist afterwards.  
	<b>Returns:</b> The client's updated list of playlists (the new one is last), or `false` if the name is empty or `Config.maxPlaylists` is reached.

7. <b>Server Callback</b> - Play Video with ID:  
	`'Frantic_Youtube:server:PlayVideoWithID'` 

	Plays a video for the source client and adds it to the video history.

	<b>Example arguments to Pass:</b>
	```lua
	data = 'dQw4w9WgXcQ' -- YouTube ID or URL of the video to play. A table with a url field also works.
	```
	<b>Returns:</b> Video data (`url`, `title`, `author`, `duration`) or `false` if the video can't be embedded, doesn't exist, or the request came within `Config.playCooldown`.

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

10. <b>Server Callback</b> - Get Video Data:  
	`'Frantic_Youtube:server:GetVideoData'` 

	Looks up a video without playing it.

	<b>Example arguments to Pass:</b>
	```lua
	data = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ' -- YouTube ID or URL
	```
	<b>Returns:</b> Video data (`duration` is 0 if no one has played it yet) or `false`.

10b. <b>Server Callback</b> - Search Videos:  
	`'Frantic_Youtube:server:SearchVideos'` 

	Keyword search, or a pasted URL/ID. Runs on the server: with `set frantic_youtube_api_key "KEY"` in server.cfg it uses the YouTube Data API v3, otherwise it reads YouTube's results page (no key needed, but it can break when YouTube changes that page). Results are cached for `Config.searchCacheLifetime` seconds.  
	With `Config.searchMode = 'single'`, keyword search is off: only pasted links/IDs return a result (an empty list otherwise). Use it as a fallback if keyword search breaks.

	<b>Example arguments to Pass:</b>
	```lua
	query = 'rick astley'
	```
	<b>Returns:</b> Up to `Config.searchResultCount` videos (`url`, `title`, `author`, `duration`), or `false` (empty query, `Config.searchCooldown`, or the search failed; the server console says which).

11. <b>Client Event Handler</b> - Own Video Updated (For your Resource):  
	`'Frantic_Youtube:client:OwnVideoUpdated'` 

	Raised locally on the client with the player's own speaker: on every change, and once a second while it exists. The argument is `nil` once the speaker is gone.  
	Replaces the old `UpdateVideoDataResource` event, which sent every speaker on the server ten times a second.

	<b>Example argument:</b>
	```lua
	videoData = {
		videoUrl = 'dQw4w9WgXcQ',	-- YouTube ID of Current Video
		title = 'Never Gonna Give You Up',
		author = 'Rick Astley',
		videoCurrentTime = 152,	-- Current Video Time (seconds)
		videoDuration = 220,	-- Total Duration (seconds). 0 until the owner's player has loaded the video.
		videoState = 1,		-- 1 = Playing, 2 = Paused, 0 = Ended/Stopped
		videoLoaded = true,	-- Has the owner's player started the video?
		videoSpeakerVolume = 1,	-- Speaker Volume of the Owner Client
	}
	```

12. <b>Client Exports</b>  
	`exports['Frantic_Youtube']:GetOwnVideoData()` returns the same table for the player's own speaker, or `nil`.  
	`exports['Frantic_Youtube']:GetVideoData(serverId)` returns it for any player's speaker, or `nil`.

13. <b>Command</b>  
	`/playvideo <YouTube URL or ID>` plays a video on your own speaker.

