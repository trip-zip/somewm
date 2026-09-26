local runner = require("_runner")
local utils = require("_utils")
local awful = require("awful")
local wibox = require("wibox")

local binary = utils.binary_or_skip("./build-test/test-transient-client")
if not binary then return end

local s = screen.primary
local t = s.selected_tag
local clients, reports = {}, {}
local master, w

local function boxes(x, y, w)
    return string.format("box %d,%d %dx30 rbox %d,%d %dx30", x, y, w, x, y, w)
end

runner.run_steps({
    function(count)
        if count == 1 then
            t.layout = awful.layout.suit.tile
            t.gap = 0
            t.master_width_factor = 0.5505
            w = s.workarea.width * 0.5505
            assert(w - math.floor(w) >= 0.5,
                "fixture width is not fractional above a half: " .. w)
            for i = 1, 2 do
                reports[i] = os.tmpname()
                awful.spawn { binary, "CLIP_ROUND_" .. i, reports[i], "0", "ff336699", "0" }
            end
        end
        for i = 1, 2 do
            clients[i] = utils.find_client_by_class("CLIP_ROUND_" .. i)
            if not clients[i] then
                assert(count < 20, "clip client did not map: CLIP_ROUND_" .. i)
                return
            end
        end
        for _, c in ipairs(clients) do
            c.floating, c.shadow, c.border_width = false, false, 0
        end
        return true
    end,
    function(count)
        local a, b = clients[1]:geometry().width, clients[2]:geometry().width
        if a == b then
            assert(count < 20, "the tiled client widths never differed")
            return
        end
        master = a > b and clients[1] or clients[2]
        awful.titlebar(master, { size = 30 }):setup {
            nil,
            nil,
            wibox.widget {
                forced_width = 30, forced_height = 30, bg = "#ff0000",
                widget = wibox.container.background,
            },
            layout = wibox.layout.align.horizontal,
        }
        return true
    end,
    function(count)
        local dump = awesome._clay_tree(s)
        local client_line, declaration, scissor, rectangle, leaf, id
        local named = "titlebar " .. master.class
        for line in dump:gmatch("[^\n]+") do
            if line:find("CLIENT " .. master.class .. " ", 1, true) then
                client_line = line
            end
            if line:find("TITLEBAR " .. master.class .. " converted:", 1, true) then
                declaration = line
            end
            if line:find(named, 1, true) and line:find("SCISSOR_START", 1, true) then
                scissor = line
                id = line:match("^%s*(%x%x%x%x%x%x%x%x) ")
            end
        end
        for line in dump:gmatch("[^\n]+") do
            if line:find(named, 1, true) and line:find("RECTANGLE", 1, true) then
                if id and line:match("^%s*(%x%x%x%x%x%x%x%x) ") == id then
                    rectangle = line
                elseif line:match(" box %-?%d+,%-?%d+ 30x30 ") then
                    leaf = line
                end
            end
        end
        if not declaration or not scissor or not rectangle or not leaf then
            assert(count < 20, "the converted titlebar nodes never appeared:\n" .. dump)
            return
        end
        assert(client_line, "missing CLIENT " .. master.class .. "\n" .. dump)
        local pl, pt, pr, pb = client_line:match("pad (%d+),(%d+),(%d+),(%d+)")
        pl, pt, pr, pb = tonumber(pl), tonumber(pt), tonumber(pr), tonumber(pb)
        assert(pl and pt and pr and pb, "expected client padding: " .. client_line)
        local width = math.floor(w + 0.5) - pl - pr
        local evidence = os.getenv("SOMEWM_EXAMPLE_EVIDENCE")
        if evidence then
            local file = assert(io.open(evidence .. "/titlebar-clip-rounding.txt", "w"))
            file:write(declaration, "\n", scissor, "\n", rectangle, "\n", leaf, "\n")
            file:close()
        end
        assert(declaration:find(" " .. width .. "x30", 1, true), declaration)
        local x, y = declaration:match(" box (%-?%d+),(%-?%d+) ")
        x, y = tonumber(x), tonumber(y)
        assert(rectangle:find(boxes(x, y, width), 1, true), rectangle)
        assert(scissor:find(boxes(x, y, width), 1, true), scissor)
        assert(leaf:find(boxes(x + width - 30, y, 30), 1, true), leaf)
        for line in dump:gmatch("[^\n]+") do
            if line:find(named, 1, true) then
                assert(not line:find("[solved!=realized]", 1, true), line)
            end
            assert(not line:find("[tree!=scene]", 1, true), line)
        end
        for _, c in ipairs(clients) do c:kill() end
        return true
    end,
    function(count)
        for _, c in ipairs(clients) do
            if c.valid then
                assert(count < 20, "the clip client did not exit: " .. c.class)
                return
            end
        end
        for _, report in ipairs(reports) do os.remove(report) end
        return true
    end,
}, { kill_clients = false })
