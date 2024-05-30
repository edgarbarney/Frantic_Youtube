# Frantic's Youtube Player Library for QBCore

This is a library for playing YouTube videos as sounds in the background in FiveM's QBCore Framework.  

Because it doesn't download or stream anything, it complies with YouTube ToS. It's built completely upon YouTube's API.

This is not a standalone asset; as stated, it's a 'library' for other assets to use.

Credit to FranticDreamer is not required, but hugely appreciated.

## General Information
Videos are networked, and listenable by everyone in a certain radius.  
Radius is in the config.lua  
  
Default settings:  
Server updates clients every second.  
Client updates videos every 10th of a second.  


## Installation
Try one of the working methods below
### Older QBCore
1. Download the Latest Release.
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
1. Download the Latest Release.
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
TODO.