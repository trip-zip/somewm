---------------------------------------------------------------------------
--- Helper for the pointer target scenarios (tests/test-pointer-target-*.lua
--- and tests/test-xwayland-pointer-target.lua).
---
--- A scenario maps test clients that append the pointer events they receive
--- to a marker file, injects input with test-virtual-pointer-client so it
--- takes the real motionnotify() and buttonpress() path, and compares which
--- client received the press with the one the scenario expects.
---
--- Every scenario runs even when an earlier one fails. probe.finish() fails
--- the test with the list of scenarios that did not hold.
---------------------------------------------------------------------------

local async = require("_async")
local awful = require("awful")
local ruled = require("ruled")
local utils = require("_utils")

local probe = {}

local BIN = "./build-test/"
local VPOINTER = BIN .. "test-virtual-pointer-client"
local LOGGER   = BIN .. "test-pointer-logger"
local X11      = BIN .. "test-x11-grab-client"
local POPUP    = BIN .. "test-popup-client"
local LAYER    = BIN .. "test-layer-client"

-- Polls read small marker files, so they can be frequent.
local POLL = 0.02

--- Two boxes most scenarios use: a large window and a small one inside it.
probe.BIG   = { x = 300, y = 60,  width = 500, height = 400 }
probe.SMALL = { x = 450, y = 180, width = 200, height = 150 }

local handles = {}
local results = {}
local stamp = os.time() * 1000 + math.random(0, 999)
local serial = 0

--- Skips the test when a helper binary is missing. The caller returns from
--- its chunk when this answers true.
function probe.missing()
    for _, bin in ipairs({ VPOINTER, LOGGER, X11, POPUP, LAYER }) do
        if not utils.binary_or_skip(bin) then return true end
    end
end

local function new_handle(name, press_pattern)
    serial = serial + 1
    local h = {
        name = name,
        press_pattern = press_pattern,
        marker = string.format("/tmp/somewm-pointer-%d-%d-%s.log", stamp, serial, name),
    }
    os.remove(h.marker)
    handles[#handles + 1] = h
    return h
end

local function spawn(h, ...)
    h.pid = awful.spawn(string.format(...))
    assert(type(h.pid) == "number", "spawn returned: " .. tostring(h.pid))
end

--- Every line the handle's client has logged.
function probe.lines(h)
    local out = {}
    local f = io.open(h.marker, "r"); if not f then return out end
    for line in f:lines() do out[#out + 1] = line end
    f:close()
    return out
end

--- How many logged lines match a Lua pattern.
function probe.count(h, pattern)
    local n = 0
    for _, line in ipairs(probe.lines(h)) do
        if line:match(pattern) then n = n + 1 end
    end
    return n
end

--- How many button presses the handle's client has received. A handle
--- whose client does not log presses always answers 0.
function probe.presses(h)
    return h.press_pattern and probe.count(h, h.press_pattern) or 0
end

--- Wait until the handle's client has logged a line matching the pattern.
function probe.wait_for(h, pattern, timeout)
    return async.wait_for_condition(function()
        return probe.count(h, pattern) > 0
    end, timeout or 3, POLL)
end

local function place(class, box)
    ruled.client.append_rule {
        rule = { class = class },
        properties = { floating = true, x = box.x, y = box.y,
                       width = box.width, height = box.height },
    }
end

local function wait_placed(h, class, box)
    h.c = async.wait_for_client(class, 10)
    assert(h.c, class .. " did not appear")
    -- The rule's box reaches c:geometry() once the client has taken it.
    async.wait_for_condition(function()
        local g = h.c:geometry()
        return g.x == box.x and g.y == box.y
    end, 3, POLL)
    return h
end

--- A Wayland toplevel that logs enter, motion, leave, button and axis.
-- @tparam string name The app id, unique within the test.
-- @tparam table box x, y, width, height.
-- @tparam[opt] string extra Extra test-pointer-logger arguments.
function probe.wayland(name, box, extra)
    local h = new_handle(name, "^button %d+ 1$")
    place(name, box)
    spawn(h, "%s --app-id %s --marker %s --size %dx%d %s",
        LOGGER, name, h.marker, box.width, box.height, extra or "")
    return wait_placed(h, name, box)
end

--- A managed X11 window that logs MAP, ENTER and BUTTON press/release.
function probe.x11(name, box)
    local h = new_handle(name, "^BUTTON press$")
    place(name, box)
    -- An X11 client's map queues a request::activate that raises it. It is
    -- delivered after request::manage, so a scenario that set its order
    -- without waiting for it would have the order changed under it.
    local activated = false
    local function on_activate(c, context)
        if c.class == name and context == "xwayland_map" then activated = true end
    end
    client.connect_signal("request::activate", on_activate)
    spawn(h, "%s %s %s %d %d %d %d no-grab",
        X11, h.marker, name, box.x, box.y, box.width, box.height)
    local placed, err = pcall(wait_placed, h, name, box)
    local seen = placed and async.wait_for_condition(function() return activated end, 3, POLL)
    client.disconnect_signal("request::activate", on_activate)
    assert(placed, err)
    assert(seen, name .. " was not activated at map")
    assert(h.c.window and h.c.window > 0, name .. " is not an XWayland client")
    return h
end

local function x11_unmanaged(name, box, mode)
    local h = new_handle(name, "^BUTTON press$")
    spawn(h, "%s %s %s %d %d %d %d %s",
        X11, h.marker, name, box.x, box.y, box.width, box.height, mode)
    assert(probe.wait_for(h, "^MAP$", 10), name .. " did not map")
    return h
end

--- An override-redirect X11 window. The handle has no `c`.
function probe.x11_override(name, box) return x11_unmanaged(name, box, "override") end

--- An override-redirect X11 window typed as a popup menu, which marks it as
--- a window that does not want keyboard focus. The handle has no `c`.
function probe.x11_menu(name, box) return x11_unmanaged(name, box, "menu") end

--- The popup client. Returns the parent's handle and the popup's handle; they
--- share one process and one marker file. The popup is not open yet, see
--- probe.open_popup().
function probe.popup_client(box)
    local parent = new_handle("popup_test", "^button parent 1$")
    place("popup_test", box)
    spawn(parent, "%s %s", POPUP, parent.marker)
    wait_placed(parent, "popup_test", box)
    local popup = { name = "popup", press_pattern = "^button popup 1$",
                    marker = parent.marker }
    handles[#handles + 1] = popup
    return parent, popup
end

--- Ask the popup client to open its popup (SIGUSR1). It hangs off the
--- parent's bottom-right corner and is 120 by 120.
function probe.open_popup(parent)
    awesome.kill(parent.pid, 10)
end

--- A mapped layer surface, with its box in `geometry`. The layer client logs
--- "entered" on wl_pointer.enter and no presses, so its handle is read with
--- probe.count().
function probe.layer(name, args)
    local h = new_handle(name, nil)
    spawn(h, "%s --namespace %s --pointer-marker %s %s", LAYER, name, h.marker, args)
    assert(async.wait_for_condition(function()
        for _, ls in ipairs(layer_surface.get()) do
            if ls.namespace == name and ls.geometry.width > 0 then
                h.geometry = ls.geometry
                return true
            end
        end
    end, 5, POLL), "the layer surface did not map")
    async.sleep(0.2)
    return h
end

--- Warm up lazy Xwayland: its first client races its map and may never
--- appear, so spawn one and discard it.
function probe.warm_x11()
    local pid = awful.spawn(string.format("%s /dev/null warmup_x11 0 0 50 50", X11))
    assert(type(pid) == "number", "warm-up spawn failed: " .. tostring(pid))
    local wc
    async.wait_for_condition(function()
        wc = utils.find_client_by_title("warmup_x11")
        return wc ~= nil
    end, 10, POLL)
    assert(wc, "warm-up X client did not appear")
    awesome.kill(pid, 9)
    async.wait_for_condition(function() return not wc.valid end, 5, POLL)
    async.sleep(0.2)
end

-- The pointer client's command line: a mode, what the mode takes before the
-- screen size (its points), then what it takes after.
local function pointer_cmd(mode, points, ...)
    local sg = screen[1].geometry
    local cmd = { VPOINTER, mode }
    for _, v in ipairs(points) do cmd[#cmd + 1] = tostring(math.floor(v)) end
    cmd[#cmd + 1], cmd[#cmd + 2] = tostring(sg.width), tostring(sg.height)
    for _, v in ipairs({ ... }) do cmd[#cmd + 1] = tostring(v) end
    return cmd
end

--- Start the pointer client and return at once.
-- @usage probe.start("drag", { x1, y1, x2, y2 }, 800)
function probe.start(mode, points, ...)
    awful.spawn(pointer_cmd(mode, points, ...))
end

--- Run the pointer client and return once it has exited. Its last roundtrip
--- returns after the compositor dispatched its events, so every binding they
--- fire has run by then.
-- @usage probe.run("click", { x, y }, "left")
-- @usage probe.run("drag", { x1, y1, x2, y2 }, 150, "left")
-- @usage probe.run("scroll", { x, y }, "down")
function probe.run(mode, points, ...)
    local done, code, err
    awful.spawn.easy_async(pointer_cmd(mode, points, ...), function(_, stderr, _, exitcode)
        done, code, err = true, exitcode, stderr
    end)
    assert(async.wait_for_condition(function() return done end, 10, 0.01),
        "the pointer client did not exit")
    assert(code == 0, "the pointer client failed: " .. tostring(err))
end

--- Move the pointer to a layout point.
function probe.move(x, y) probe.start("move", { x, y }) end
--- Move to a layout point, then press and release the left button.
function probe.click(x, y) probe.start("click", { x, y }) end
--- Press and release where the pointer is, with no motion.
function probe.button() probe.start("button", { 0, 0 }) end
--- One motion, the press and the release in a single write.
function probe.jumpclick(x, y) probe.start("jumpclick", { x, y }) end
--- Press at one point, move to another, hold for hold_ms, release.
function probe.drag(x1, y1, x2, y2, hold_ms)
    probe.start("drag", { x1, y1, x2, y2 }, hold_ms)
end

--- The default config's left-click binding. tests/rc.lua has none, and a
--- click that activates its client is what a user's session does.
function probe.bind_click_to_activate()
    awful.mouse.append_client_mousebindings({
        awful.button({ }, 1, function(c)
            c:activate { context = "mouse_click" }
        end),
    })
end

--- Raise `top` and wait until the stacking order has it above each of the
--- other handles, then give the frame time to follow.
function probe.raise_over(top, ...)
    local below = { ... }
    top.c:raise()
    assert(async.wait_for_condition(function()
        for _, b in ipairs(below) do
            if not probe.is_above(top, b) then return false end
        end
        return true
    end, 3, POLL), top.name .. " is not on top of the stacking order")
    async.sleep(0.2)
end

--- The center of a handle's client or layer surface, in layout coordinates.
function probe.center(h)
    local g = h.geometry or h.c:geometry()
    return math.floor(g.x + g.width / 2), math.floor(g.y + g.height / 2)
end

--- Whether `top` is above `bottom` in the stacking order.
function probe.is_above(top, bottom)
    for _, c in ipairs(client.get(top.c.screen, true)) do
        if c == top.c then return true end
        if c == bottom.c then return false end
    end
end

--- Inject, then compare who received a press with who should have.
-- @tparam function act Injects the input. With no target it must return
--   only after the input was sent (probe.run), since there is no press to
--   wait for.
-- @tparam table|nil target The handle that must receive exactly one press,
--   or nil when no client may receive one.
-- @treturn boolean Whether it held.
-- @treturn string One line naming every handle's count.
function probe.expect_press(act, target)
    local before = {}
    for _, h in ipairs(handles) do before[h] = probe.presses(h) end
    act()
    if target then
        async.wait_for_condition(function()
            for _, h in ipairs(handles) do
                if probe.presses(h) > before[h] then return true end
            end
        end, 3, POLL)
    end
    -- A press that goes to the wrong client may arrive after the right one.
    async.sleep(0.3)

    local ok, parts = true, {}
    for _, h in ipairs(handles) do
        local got = probe.presses(h) - before[h]
        local want = h == target and 1 or 0
        if got ~= want then ok = false end
        if got ~= 0 or want ~= 0 then
            parts[#parts + 1] = string.format("%s=%d", h.name, got)
        end
    end
    return ok, string.format("expected %s, presses: %s",
        target and target.name or "nobody",
        #parts > 0 and table.concat(parts, " ") or "none")
end

--- Close every client and forget every handle. Call between scenarios.
function probe.reset()
    for _, c in ipairs(client.get()) do
        if c.valid then c:kill() end
    end
    for _, h in ipairs(handles) do
        if h.pid then awesome.kill(h.pid, 9) end
        os.remove(h.marker)
    end
    handles = {}
    async.wait_for_condition(function()
        return #client.get() == 0 and #layer_surface.get() == 0
    end, 5, POLL)
    -- Park the pointer on the empty desktop so the next scenario starts with
    -- no pointer focus.
    probe.run("move", { 5, screen[1].geometry.height - 5 })
end

--- Run one scenario. `fn` returns ok and a detail line, or raises.
function probe.scenario(number, title, fn)
    local ran, ok, detail = pcall(fn)
    if not ran then ok, detail = false, tostring(ok) end
    results[#results + 1] = { number = number, ok = ok }
    io.stderr:write(string.format("[SCENARIO %s] %s: %s (%s)\n", tostring(number),
        ok and "PASS" or "FAIL", title, tostring(detail)))
    probe.reset()
end

--- Fail the test when any scenario did not hold.
function probe.finish()
    local failed = {}
    for _, r in ipairs(results) do
        if not r.ok then failed[#failed + 1] = tostring(r.number) end
    end
    assert(#failed == 0, "pointer scenarios that did not hold: " .. table.concat(failed, ", "))
    io.stderr:write("[ALL TESTS] PASS\n")
end

return probe

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
