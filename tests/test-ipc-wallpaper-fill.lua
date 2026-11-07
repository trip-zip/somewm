local runner = require("_runner")
local ipc = require("awful.ipc")
local cairo = require("lgi").cairo

local s = screen[1]
local geo = s.geometry
local sw, sh = geo.width, geo.height
local scale = math.max(sw / 200, sh / 100)
local cw, ch = 200 * scale, 100 * scale
local path = assert(os.getenv("SOMEWM_TEST_LOG")):match("^(.*)/") .. "/wallpaper-fill.png"

local function command(name)
    local reply = ipc.dispatch("wallpaper " .. name .. " " .. path .. " 1")
    assert(reply:match("^OK\n"), reply)
end

local function wallpaper_image()
    local dump = awesome._clay_tree(s)
    local inside, id, source
    for line in dump:gmatch("[^\n]+") do
        if line:match("^%s*WALLPAPER screen " .. s.index .. " ") then
            inside = true
        elseif inside and line:match("^%s*%x+%s+") then
            if line:match(" image %d+x%d+") then
                assert(not id, "multiple wallpaper images: " .. dump)
                id = line:match("^%s*(%x+)")
                source = line
            end
        elseif inside then
            inside = false
        end
    end
    assert(id, "no wallpaper image: " .. dump)
    for line in dump:gmatch("[^\n]+") do
        if line:match("^%s*" .. id .. "%s+IMAGE ") then
            local x, y, w, h = line:match(" box (%-?%d+),(%-?%d+) (%d+)x(%d+)")
            assert(x, line)
            io.stderr:write("[IMAGE] " .. source .. "\n[IMAGE] " .. line .. "\n")
            return tonumber(x), tonumber(y), tonumber(w), tonumber(h), source
        end
    end
    error("wallpaper image was not realized: " .. dump)
end

local function near(got, want, name)
    assert(math.abs(got - want) <= 1,
        string.format("%s: got %g, expected %g", name, got, want))
end

runner.run_steps {
    function()
        assert(sw / sh ~= 2, "screen must differ from the image's 2:1 aspect")
        local image = cairo.ImageSurface.create(cairo.Format.ARGB32, 200, 100)
        local cr = cairo.Context(image)
        cr:set_source_rgb(0.2, 0.4, 0.6)
        cr:paint()
        image:write_to_png(path)
        assert(io.open(path, "rb")):close()
        command("fill")
        return true
    end,
    function(count)
        if count == 1 then return nil end
        local x, y, w, h, source = wallpaper_image()
        -- Check source dimensions before geometry to identify a pre-rendered image.
        assert(source:match(" image 200x100 "),
            "wallpaper.fill must retain the 200x100 source: " .. source)
        io.stderr:write("[PASS] wallpaper.fill retains the 200x100 source\n")
        near(w, cw, "cover width")
        near(h, ch, "cover height")
        near(x, -(cw - sw) / 2, "cover x")
        near(y, -(ch - sh) / 2, "cover y")
        if sw / 200 > sh / 100 then
            assert(w == sw and x == 0 and y < 0, "cover must overflow vertically")
        else
            assert(h == sh and y == 0 and x < 0, "cover must overflow horizontally")
        end
        io.stderr:write("[PASS] wallpaper.fill covers the screen with centered overflow\n")
        command("set")
        return true
    end,
    function(count)
        if count == 1 then return nil end
        local _, _, w, h = wallpaper_image()
        local contain = math.min(sw / 200, sh / 100)
        near(w, 200 * contain, "contained width")
        near(h, 100 * contain, "contained height")
        assert(w <= sw and h <= sh and (w < sw or h < sh),
            "wallpaper.set must leave borders")
        io.stderr:write("[PASS] wallpaper.set contains the image instead of covering\n")
        assert(os.remove(path))
        return true
    end,
}
