--- Client related mouse operations.
--
-- @author Emmanuel Lepage Vallee &lt;elv1313@gmail.com&gt;
-- @copyright 2016 Emmanuel Lepage Vallee
-- @submodule mouse

local aplace = require("awful.placement")
local capi = { mouse = mouse, client = client }
local mresize = require("awful.mouse.resize")
local gdebug = require("gears.debug")

local module = {}

--- Move a client.
-- @staticfct awful.mouse.client.move
-- @tparam client c The client to move, or the focused one if nil.
-- @param snap The pixel to snap clients.
-- @noreturn
-- @request client geometry mouse.move granted When `awful.mouse.client.move` is
--  called.
function module.move(c, snap, finished_cb) --luacheck: no unused args
    c = c or capi.client.focus

    if not c
        or c.fullscreen
        or c.maximized
        or c.type == "desktop"
        or c.type == "splash"
        or c.type == "dock" then
        return
    end

    -- Compute the offset
    local coords = capi.mouse.coords()
    local geo    = aplace.centered(capi.mouse,{parent=c, pretend=true})

    local offset = {
        x = geo.x - coords.x,
        y = geo.y - coords.y,
    }

    mresize(c, "mouse.move", {
        placement = aplace.under_mouse,
        offset    = offset,
        snap      = snap
    })
end

--- Resize a client.
-- @staticfct awful.mouse.client.resize
-- @param c The client to resize, or the focused one by default.
-- @tparam string corner The corner to grab on resize. Auto detected by default.
-- @tparam[opt={}] table args A set of `awful.placement` arguments
-- @treturn string The corner (or side) name
-- @request client geometry mouse.resize granted When `awful.mouse.client.resize`
--  is called.
function module.resize(c, corner, args)
    c = c or capi.client.focus

    if not c then return end

    if c.fullscreen
        or c.maximized
        or c.type == "desktop"
        or c.type == "splash"
        or c.type == "dock" then
        return
    end

    -- Set some default arguments
    local new_args = setmetatable(
        {
            include_sides = (not args) or args.include_sides ~= false
        },
        {
            __index = args or {}
        }
    )

    -- Move the mouse to the corner
    if corner and aplace[corner] then
        aplace[corner](capi.mouse, {parent=c})
    else
        local _
        _, corner = aplace.closest_corner(capi.mouse, {
            parent        = c,
            include_sides = new_args.include_sides ~= false,
        })
    end

    new_args.corner = corner

    mresize(c, "mouse.resize", new_args)

    return corner
end

return module
