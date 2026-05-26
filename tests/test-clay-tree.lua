---------------------------------------------------------------------------
--- Test: the `clay tree` IPC command prints the screen's Clay descriptor tree.
--
-- After a tile-layout arrange with a widgeted wibar and a tiled client, the
-- screen's descriptor tree is captured (`s._clay_last_tree`) and the
-- `clay.tree` IPC command renders it as text containing the client, the wibar
-- drawin, and a widget node. Also checks the --json structured form.
---------------------------------------------------------------------------

local runner = require("_runner")
local test_client = require("_client")
local utils = require("_utils")
local awful = require("awful")
local wibox = require("wibox")

if not test_client.is_available() then
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local clay = require("awful.layout.clay")
local ipc = require("awful.ipc")

local s = screen.primary
local tag = s.tags[1]
local bar

local steps = {
    -- tile layout + a wibar with a textbox widget.
    function()
        tag:view_only()
        tag.layout = clay.tile
        tag.gap = 0
        local root = wibox.layout.fixed.horizontal(wibox.widget.textbox("hello"))
        bar = awful.wibar { position = "top", screen = s, height = 20, widget = root }
        io.stderr:write("[TEST] set clay.tile + widgeted wibar\n")
        return true
    end,

    -- Wait for the wibar's first draw.
    function(count)
        if bar._drawable._widget_hierarchy then return true end
        if count >= 20 then error("wibar never drew its hierarchy") end
        return nil
    end,

    -- Spawn a tiled client with a real border so the tree shows a nonzero width.
    function(count)
        if count == 1 then test_client("clay_tree") end
        local c = utils.find_client_by_class("clay_tree")
        if c then c.border_width = 4 end
        return c and true or nil
    end,

    -- Arrange, then wait until the printed tree reflects the client, and check
    -- the text output contains the expected nodes.
    function(count)
        if count == 1 then
            awful.layout.arrange(s)
            return nil
        end
        local resp = ipc.dispatch("clay tree", -1)
        if type(resp) == "string" and resp:find("client.clay_tree", 1, true) then
            io.stderr:write("[TEST] clay tree response:\n" .. resp .. "\n")
            assert(resp:match("^OK\n"), "clay tree should return OK")
            assert(resp:find("screen", 1, true), "tree should contain the screen root")
            assert(resp:find("drawin", 1, true) and resp:find("wibar", 1, true),
                "tree should contain the wibar drawin node")
            assert(resp:match("\n%s*widget [^\n]*%[%-?%d"),
                "a widget node should show its solved box")
            -- Borders are a Clay `.border` on the client body column now, not
            -- four `frame.border_*` leaves: the body shows `border=` and there
            -- are no border frame_box nodes.
            assert(not resp:find("frame.border", 1, true),
                "client borders should no longer be frame_box leaves")
            assert(resp:find("border=4", 1, true),
                "the client body column should declare its Clay border width")
            io.stderr:write("[TEST] PASS: clay tree printed client + wibar nodes\n")
            return true
        end
        if count >= 15 then error("clay tree never showed the client node") end
        return nil
    end,

    -- --json returns a structured tree.
    function()
        local resp = ipc.dispatch("--json clay tree", -1)
        assert(type(resp) == "string", "json dispatch should return a string")
        assert(resp:find('"tree"', 1, true), "json mode should include a tree key")
        assert(resp:find('"type"', 1, true), "json nodes should have a type")
        io.stderr:write("[TEST] PASS: clay tree --json produced structured output\n")
        return true
    end,

    -- Unknown screen index errors cleanly.
    function()
        local resp = ipc.dispatch("clay tree 999", -1)
        assert(resp:match("^ERROR"), "an invalid screen index should error")
        io.stderr:write("[TEST] PASS: invalid screen index errors\n")
        return true
    end,

    -- Cleanup.
    function(count)
        if count == 1 then
            bar.visible = false
            for _, c in ipairs(client.get()) do
                if c.valid then c:kill() end
            end
        end
        if #client.get() == 0 then return true end
        if count >= 10 then
            for _, pid in ipairs(test_client.get_spawned_pids()) do
                os.execute("kill -9 " .. pid .. " 2>/dev/null")
            end
            return true
        end
    end,
}

runner.run_steps(steps, { kill_clients = false })
