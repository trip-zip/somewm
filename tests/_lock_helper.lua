---------------------------------------------------------------------------
-- Lock test helper - shared setup/teardown for lockscreen integration tests.
---------------------------------------------------------------------------

local wibox = require("wibox")
local awful = require("awful")

local lock_helper = {}

lock_helper.TEST_PASSWORD = "testpass123"

--- Create a wibox suitable for use as a lock surface and register it.
-- @treturn wibox The created wibox
function lock_helper.setup()
    local s = awful.screen.focused()
    local wb = wibox({
        x = s.geometry.x,
        y = s.geometry.y,
        width = s.geometry.width,
        height = s.geometry.height,
        visible = false,
        ontop = true,
        bg = "#000000",
    })
    awesome.set_lock_surface(wb)
    return wb
end

--- Create an interactive wibox + cover wiboxes for all screens.
-- @treturn table {interactive=wibox, covers={wibox,...}}
function lock_helper.setup_multiscreen()
    local result = { interactive = nil, covers = {} }
    for s in screen do
        local wb = wibox({
            x = s.geometry.x,
            y = s.geometry.y,
            width = s.geometry.width,
            height = s.geometry.height,
            visible = false,
            ontop = true,
            bg = "#000000",
        })
        if not result.interactive then
            awesome.set_lock_surface(wb)
            result.interactive = wb
        else
            awesome.add_lock_cover(wb)
            table.insert(result.covers, wb)
        end
    end
    return result
end

--- Teardown: authenticate if locked, unlock, clear surfaces.
function lock_helper.teardown()
    if awesome.locked then
        awesome.authenticate(lock_helper.TEST_PASSWORD)
        awesome.unlock()
    end
    awesome.clear_lock_surface()
    awesome.clear_lock_covers()
end

--- Lock, authenticate, and return state.
-- @treturn boolean true if lock+auth succeeded
function lock_helper.lock_and_auth()
    local locked = awesome.lock()
    if not locked then return false end
    local authed = awesome.authenticate(lock_helper.TEST_PASSWORD)
    return authed
end

return lock_helper

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
