Config = Config or {}

-- Print what happens (searches, plays, pauses, seeks, player pool changes) to the server console and the F8 console.
Config.debug = true

-- ========================
-- Audibility
-- ========================

-- Distance (metres) at which a speaker fades to silence. Matches PMA Voice's shouting distance.
-- TODO: Interface with PMA Voice
Config.maxDistance = 15.0

-- A speaker that already holds a player keeps it until it is this far away, so walking along the edge of maxDistance doesn't reload the video over and over.
Config.releaseDistance = 20.0

-- Most YouTube players (Chromium iframes) a client keeps at once. The nearest speakers win; the player's own speaker always gets one.
-- This is the main performance knob: every player is a full YouTube page decoding video in the background.
Config.maxActivePlayers = 2

-- How long (seconds) an unused YouTube player stays alive for reuse before it is destroyed.
Config.idlePlayerLifetime = 60

-- How often (ms) a client recalculates speaker volumes while any speaker exists. Idle clients check once a second.
Config.clientRefreshRate = 250

-- How far (seconds) a client's playback may drift from the server's timeline before it seeks back.
Config.driftTolerance = 3.0

-- ========================
-- Volumes
-- ========================

Config.defaultListenerVolume = 0.5 -- (0.0 - 1.0)
Config.defaultSpeakerVolume = 1.0 -- (0.0 - 1.0)

-- ========================
-- Limits
-- ========================

Config.playCooldown = 1000 -- ms between play requests from one player
Config.metadataTimeout = 8000 -- ms to wait for YouTube's oEmbed endpoint
Config.maxVideoDuration = 24 * 60 * 60 -- seconds; longer reported durations are rejected
Config.maxHistory = 100 -- Played videos remembered per citizen; oldest are dropped first
Config.maxPlaylists = 50
Config.maxPlaylistSize = 200
Config.maxPlaylistNameLength = 50

-- ========================
-- Search
-- ========================

-- Searches run on the server. With the convar below set, the YouTube Data API v3 is used (100 quota units per search; the free quota is 10,000 a day).
-- Without it, the server reads YouTube's own results page, which needs no key but can break whenever YouTube changes that page.
-- The key is a convar on purpose: this file is shared, so every client downloads it.
--   set frantic_youtube_api_key "YOUR_KEY"
-- 'multiple': keywords return up to searchResultCount videos, and a pasted link returns that one video.
-- 'single': only pasted links/IDs work (checked through oEmbed); keyword searches return nothing. Fallback for when keyword search breaks or you don't want it.
Config.searchMode = 'multiple'
Config.searchResultCount = 8 -- (1 - 20)
Config.searchCooldown = 1500 -- ms between searches from one player
Config.searchCacheLifetime = 600 -- seconds a query's results are reused
