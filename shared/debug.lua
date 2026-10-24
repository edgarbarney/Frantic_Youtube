-- Prints to the server console on the server and to the F8 console on clients, when Config.debug is on.
-- message is a string.format template; pass values as extra arguments so a '%' inside a video title can't break the format.
function DebugPrint(message, ...)
    if not Config.debug then
        return
    end

    local ok, text = pcall(string.format, message, ...)
    if not ok then
        text = message
    end
    print('^5[Frantic_Youtube]^7 ' .. text)
end
