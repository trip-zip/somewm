-- Connects a class-level signal handler, then blocks past the compositor's
-- 10 second config alarm. The handler is the point: it lands in the screen
-- class's signal array, which outlives the lua_close() the abort performs.
-- Kept free of X11-looking patterns so the config prescan does not reject it.
screen.connect_signal("probe::stale", function()
    io.stderr:write("hang-class-signal: STALE HANDLER RAN\n")
end)
while true do end
