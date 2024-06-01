Config = Config or {}

-- From PMA Voice
-- TODO: Interface with PMA Voice
Config.voiceModes = {
    {3.0, "Whisper"}, -- Whisper speech distance in gta distance units
    {7.0, "Normal"}, -- Normal speech distance in gta distance units
    {15.0, "Shouting"} -- Shout speech distance in gta distance units
}

Config.serverRefreshRate = 1000 -- 1 second
Config.clientRefreshRate = 100 -- 0.1 second
