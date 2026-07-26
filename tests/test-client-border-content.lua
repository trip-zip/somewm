---------------------------------------------------------------------------
--- Regression test: border_width must not shrink the client's content.
---
--- c->geometry excludes the border; a regression that subtracts
--- border_width again when sizing the surface leaves a blank
--- 2*border_width strip at the bottom/right of every bordered client.
--- Probes c.content 3px inside the bottom-right corner, which must show
--- the pattern client's BR quadrant color (see
--- test-client-content-pattern.lua for the wl_shm pattern client).
---
--- Run: make test-one TEST=tests/test-client-border-content.lua
---------------------------------------------------------------------------

local awful  = require("awful")
local gears  = require("gears")
local runner = require("_runner")
local async  = require("_async")

local ok_ffi, ffi = pcall(require, "ffi")
if not ok_ffi then
    io.stderr:write("SKIP: ffi not available (non-LuaJIT build); pixel sampling needs FFI\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

ffi.cdef[[
void cairo_surface_flush(void *surface);
unsigned char *cairo_image_surface_get_data(void *surface);
int cairo_image_surface_get_stride(void *surface);
]]

local APP_ID = "content_pattern_test"
local BORDER_WIDTH = 12

local function find_binary()
    local somewm = os.getenv("SOMEWM") or "./build-test/somewm"
    local build_dir = somewm:match("^(.*)/somewm$") or "./build-test"
    for _, candidate in ipairs({
        build_dir .. "/test-content-pattern-client",
        "./build/test-content-pattern-client",
        "./build-test/test-content-pattern-client",
    }) do
        local f = io.open(candidate, "r")
        if f then f:close(); return candidate end
    end
    return nil
end

local BINARY = find_binary()
if not BINARY then
    io.stderr:write("SKIP: test-content-pattern-client not found (run `make` or `make build-test`)\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

-- ARGB32 is native-endian 32-bit; on little-endian the bytes are B, G, R, A.
local function pixel_rgb(raw_surface, x, y)
    ffi.C.cairo_surface_flush(raw_surface)
    local data   = ffi.C.cairo_image_surface_get_data(raw_surface)
    local stride = ffi.C.cairo_image_surface_get_stride(raw_surface)
    local off = y * stride + x * 4
    return data[off + 2], data[off + 1], data[off + 0]   -- R, G, B
end

-- Sample the corners of a fresh c.content capture. Returns nil before the
-- client has committed a full-size buffer.
local function sample_corners(c)
    local raw = c.content
    if not raw then return nil end
    local img = gears.surface(raw)
    local w, h = img:get_width(), img:get_height()
    if w < 50 or h < 50 then return nil end
    local tr, tg, tb = pixel_rgb(raw, 2, 2)
    local br, bg, bb = pixel_rgb(raw, w - 3, h - 3)
    return {
        desc = string.format("surface=%dx%d TL=rgb(%d,%d,%d) BR=rgb(%d,%d,%d)",
            w, h, tr, tg, tb, br, bg, bb),
        -- TL red proves the capture works at all; BR yellow proves the
        -- committed buffer reaches the bottom-right of the content area.
        painted = tr > 200 and tg < 80
            and br > 200 and bg > 200 and bb < 80,
    }
end

runner.run_async(function()
    local pid = awful.spawn({BINARY})
    assert(type(pid) == "number" and pid > 0,
        "Failed to spawn binary: " .. tostring(pid))

    local c = async.wait_for_client(APP_ID, 5)
    assert(c, "Pattern client never appeared")

    c.floating = true
    c.border_width = BORDER_WIDTH
    c:geometry { x = 100, y = 80, width = 300, height = 200 }

    async.wait_for_condition(function()
        local s = sample_corners(c)
        return s and s.painted
    end, 5, 0.1)

    local s = sample_corners(c)
    local desc = s and s.desc or "never captured"
    io.stderr:write("[border-content] " .. desc .. "\n")
    assert(s and s.painted,
        "bottom-right content never painted with border_width=" ..
        BORDER_WIDTH .. " (" .. desc .. "); the border is eating into " ..
        "the client's content area")

    c:kill()
    async.wait_for_no_clients(3)
    runner.done()
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
