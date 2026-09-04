---------------------------------------------------------------------------
-- Test: the solved tree dump names what the output drew
--
-- awesome._clay_tree(screen) reports the last reconcile: a header of
-- counters per band, then one line per retained node in draw order. The
-- assertions are what the dump has to be able to answer: the wibar's drawin
-- is in it, a spawned client's surface leaf and its border are in it at the
-- client's geometry, and no node anywhere disagrees with the scene, which is
-- the tree==scene check in a build with the verifier compiled out.
--
-- Run: make test-one TEST=tests/test-clay-tree-dump.lua
---------------------------------------------------------------------------

local runner = require("_runner")
local utils = require("_utils")
local lock = require("_lock_helper")
local awful = require("awful")
local wibox = require("wibox")

local TEST_CLIENT = utils.binary_or_skip("./build-test/test-transient-client")
if not TEST_CLIENT then
    return
end

local s = screen[1]
local bar, bar2, c, proc_pid, lock_surface

local function lines()
    local out = {}
    for line in awesome._clay_tree(s):gmatch("[^\n]+") do
        out[#out + 1] = line
    end
    return out
end

-- The first node line matching every pattern, or nil.
local function find(...)
    local wanted = { ... }
    for _, line in ipairs(lines()) do
        local hit = true
        for _, pattern in ipairs(wanted) do
            if not line:find(pattern, 1, true) then
                hit = false
                break
            end
        end
        if hit then
            return line
        end
    end
    return nil
end

local function assert_line(what, ...)
    local line = find(...)
    assert(line, what .. ": no such line in the dump")
    io.stderr:write("[PASS] " .. what .. ": " .. line .. "\n")
    return line
end

local function assert_agrees()
    for _, line in ipairs(lines()) do
        assert(not line:find("[tree!=scene]", 1, true),
            "the scene disagrees with the tree: " .. line)
    end
end

local steps = {
    -- The dump has a header for the desktop band before anything else is
    -- declared, and its counters come from a frame that ran.
    function()
        local header = assert_line("the desktop band header", "band desktop")
        assert(header:find("output "), "the header names no output")
        assert_line("the counters", "commands ", "mutations ", "nodes ",
            "raster_bytes ", "buffers ", "declare ", "solve ", "reconcile ")
        return true
    end,

    -- A wibar only declares once it has drawn, so wait for its drawin.
    function(count)
        if count == 1 then
            bar = awful.wibar({ position = "top", screen = s, height = 24 })
            bar:setup({
                layout = wibox.layout.fixed.horizontal,
                { widget = wibox.widget.textbox, text = "bar" },
            })
        end
        if find("drawin screen " .. s.index) then
            return true
        end
        assert(count < 20, "the wibar never reached the dump")
    end,

    function()
        assert_line("the wibar drawin", "drawin screen " .. s.index,
            string.format("%dx%d+%d+%d", bar.drawin.width, bar.drawin.height,
                bar.drawin.x, bar.drawin.y))
        -- The textbox does not convert, so it rides as a raster leaf under
        -- the converted tree and the dump names both facts.
        assert_line("the textbox raster leaf", "IMAGE",
            "widget wibox.widget.textbox raster", "raster=")
        assert_agrees()

        -- The registered command, through the dispatcher somewm-client
        -- talks to: "clay tree <index>" reaches clay.tree with the screen.
        local response = require("awful.ipc").dispatch("clay tree " .. s.index)
        assert(response:find("band desktop", 1, true),
            "clay tree did not dump the desktop band: " .. response)
        io.stderr:write("[PASS] the clay.tree ipc command\n")
        return true
    end,

    function(count)
        if count == 1 then
            proc_pid = awful.spawn(TEST_CLIENT)
        end
        c = utils.find_client_by_class("transient_test_parent")
        if c then
            return true
        end
    end,

    -- The client enters as a CUSTOM leaf for its surface and a BORDER around
    -- it, both at the frame box: the geometry plus the border ring, output
    -- local.
    function(count)
        c.border_width = 4
        local geo = c:geometry()
        local box = string.format("box %d,%d %dx%d",
            geo.x - s.geometry.x, geo.y - s.geometry.y,
            geo.width + 2 * c.border_width, geo.height + 2 * c.border_width)

        if not find("CUSTOM", box) then
            assert(count < 20, "the client never reached the dump at " .. box)
            return
        end
        assert_line("the client surface leaf", "CUSTOM", box, "client ")
        assert_line("the client border", "BORDER", box, "client ")
        assert_agrees()
        return true
    end,

    -- A second output solves in a Clay context of its own, so the dump has
    -- to read every band's boxes from the band that drew them. Reading the
    -- wrong context finds no element and prints no box.
    function(count)
        if count == 1 then
            awesome._test_add_output(800, 600)
            return nil
        end
        if screen.count() < 2 then
            assert(count < 30, "the second output never arrived")
            return nil
        end
        if not bar2 then
            bar2 = awful.wibar({ position = "top", screen = screen[2],
                height = 24 })
            bar2:setup({
                layout = wibox.layout.fixed.horizontal,
                { widget = wibox.widget.textbox, text = "two" },
            })
            return nil
        end

        local d = bar2.drawin
        local want = string.format("  drawin screen 2 %dx%d+%d+%d ",
            d.width, d.height, d.x, d.y)
        local outputs, head, tree = {}, nil, {}

        for line in awesome._clay_tree():gmatch("[^\n]+") do
            local name = line:match("^output (%S+) band desktop")

            if name then
                outputs[name] = true
                head = nil
            elseif line:sub(1, #want) == want then
                head = line
            elseif head and line:match("^    %x+ ") then
                tree[#tree + 1] = line
            elseif head then
                head = nil
            end
        end

        local count_outputs = 0

        for _ in pairs(outputs) do
            count_outputs = count_outputs + 1
        end
        assert(count_outputs >= 2,
            "the dump names " .. count_outputs .. " outputs, expected two")
        if #tree == 0 then
            assert(count < 30, "the second output's bar never converted")
            return nil
        end

        local solved = 0

        for _, line in ipairs(tree) do
            assert(not line:find("box -", 1, true),
                "a node on the second output has no box: " .. line)
            solved = solved + 1
        end
        io.stderr:write("[PASS] each output's boxes come from its own band, "
            .. solved .. " nodes\n")
        bar2.visible = false
        return true
    end,

    -- While the session is locked the lock band solves instead of the
    -- desktop one, and each band reports the drawins it draws.
    function(count)
        if count == 1 then
            lock_surface = lock.setup()
            awesome.lock()
            -- Showing the lock surface is the config's job, in its
            -- lock::activate handler; the compositor only raises the band.
            lock_surface.visible = true
            return nil
        end

        local band, found = nil, nil
        local d = lock_surface.drawin
        local want = string.format("  drawin screen %d %dx%d+%d+%d ",
            s.index, d.width, d.height, d.x, d.y)

        for _, line in ipairs(lines()) do
            local name = line:match("^output %S+ band (%S+)")

            if name then
                band = name
            elseif line:sub(1, #want) == want then
                assert(band == "lock",
                    "the lock surface is listed under the " .. band .. " band")
                found = line
            end
        end
        if not found then
            assert(count < 20, "the lock surface never reached the dump")
            return nil
        end
        assert_agrees()
        io.stderr:write("[PASS] the lock band lists its own drawins\n")
        lock.teardown()
        return true
    end,

    -- The dump reads back what the last frame retained, so asking twice
    -- with nothing moving in between answers the same thing. Each call owns
    -- a buffer, which is what the sanitizer build is watching.
    function()
        local first = awesome._clay_tree(s)

        for _ = 1, 200 do
            assert(awesome._clay_tree(s) == first,
                "two dumps of a settled scene disagree")
        end
        io.stderr:write("[PASS] a settled scene dumps the same every time\n")
        return true
    end,

    function(count)
        if count == 1 then
            bar.visible = false
            if proc_pid then
                awful.spawn("kill " .. proc_pid)
            end
        end
        if #client.get() == 0 then
            return true
        end
        if count >= 10 then
            os.execute("pkill -9 test-transient-client 2>/dev/null")
            return true
        end
    end,
}

runner.run_steps(steps, { kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
