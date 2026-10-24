Config = Config or {}

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
