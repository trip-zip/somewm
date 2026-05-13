---------------------------------------------------------------------------
-- Pixel-content test for c.content with a DMA-BUF client (issue #539).
--
-- The companion C client (test-dmabuf-pattern-client) allocates a linear
-- ARGB8888 buffer via gbm, fills it with a 4-quadrant pattern (TL=red,
-- TR=green, BL=blue, BR=yellow), and imports it through
-- zwp_linux_dmabuf_v1. The Lua driver captures c.content and asserts each
-- quadrant has its expected color. Without the scene-tree-walk fix, the
-- DMA-BUF readback path returns blank pixels (Firefox-style symptom).
--
-- Skips when:
--   * non-LuaJIT (no FFI for pixel sampling)
--   * test-dmabuf-pattern-client wasn't built (gbm dependency missing)
--   * client never appears (e.g. no /dev/dri render node in the test env)
--
-- Run: make test-one TEST=tests/test-client-content-dmabuf.lua
---------------------------------------------------------------------------

local awful  = require("awful")
local gears  = require("gears")
local runner = require("_runner")
local async  = require("_async")

local ok_ffi, ffi = pcall(require, "ffi")
if not ok_ffi then
    io.stderr:write("SKIP: ffi not available (non-LuaJIT build)\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

ffi.cdef[[
void cairo_surface_flush(void *surface);
unsigned char *cairo_image_surface_get_data(void *surface);
int cairo_image_surface_get_stride(void *surface);
int cairo_image_surface_get_width(void *surface);
int cairo_image_surface_get_height(void *surface);
]]

local APP_ID = "dmabuf_pattern_test"

local function find_binary()
    local somewm = os.getenv("SOMEWM") or "./build-test/somewm"
    local build_dir = somewm:match("^(.*)/somewm$") or "./build-test"
    for _, candidate in ipairs({
        build_dir .. "/test-dmabuf-pattern-client",
        "./build/test-dmabuf-pattern-client",
        "./build-test/test-dmabuf-pattern-client",
    }) do
        local f = io.open(candidate, "r")
        if f then f:close(); return candidate end
    end
    return nil
end

local BINARY = find_binary()
if not BINARY then
    io.stderr:write("SKIP: test-dmabuf-pattern-client not found (gbm dep missing or not built)\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local function pixel_rgb(raw_surface, x, y)
    ffi.C.cairo_surface_flush(raw_surface)
    local data   = ffi.C.cairo_image_surface_get_data(raw_surface)
    local stride = ffi.C.cairo_image_surface_get_stride(raw_surface)
    local off = y * stride + x * 4
    return data[off + 2], data[off + 1], data[off + 0]
end

local function dominant_color(r, g, b)
    if r > 200 and g <  80 and b <  80 then return "red"    end
    if g > 200 and r <  80 and b <  80 then return "green"  end
    if b > 200 and r <  80 and g <  80 then return "blue"   end
    if r > 200 and g > 200 and b <  80 then return "yellow" end
    return string.format("rgb(%d,%d,%d)", r, g, b)
end

runner.run_async(function()
    local pid = awful.spawn({BINARY})
    assert(type(pid) == "number" and pid > 0,
        "Failed to spawn binary: " .. tostring(pid))

    local c = async.wait_for_client(APP_ID, 5)
    if not c then
        os.execute("kill -9 " .. pid .. " 2>/dev/null")
        io.stderr:write("SKIP: dmabuf client never appeared (no DRM render node?)\n")
        io.stderr:write("Test finished successfully.\n")
        runner.done()
        return
    end

    -- Position the client at a non-zero scene coord. The first version of the
    -- scene-tree-walk fix (#539) used wlr_scene_node_coords as an "origin" to
    -- offset buffer positions; that math broke for any client not at (0, 0)
    -- because wlr_scene_node_for_each_buffer reports positions relative to
    -- the starting node, not scene-absolute. Tests that left the client at
    -- the screen origin missed this. Float + move to expose it.
    c.floating = true
    c:geometry { x = 137, y = 91, width = c:geometry().width, height = c:geometry().height }

    -- Give one event-loop tick for the buffer to actually attach.
    async.sleep(0.1)

    local raw = c.content
    assert(raw, "c.content returned nil")

    local img = gears.surface(raw)
    local w = img:get_width()
    local h = img:get_height()
    assert(w > 4 and h > 4,
        string.format("c.content surface too small (%dx%d)", w, h))

    local qx1, qx2 = math.floor(w * 0.25), math.floor(w * 0.75)
    local qy1, qy2 = math.floor(h * 0.25), math.floor(h * 0.75)
    local tl = dominant_color(pixel_rgb(raw, qx1, qy1))
    local tr = dominant_color(pixel_rgb(raw, qx2, qy1))
    local bl = dominant_color(pixel_rgb(raw, qx1, qy2))
    local br = dominant_color(pixel_rgb(raw, qx2, qy2))

    io.stderr:write(string.format(
        "[dmabuf] surface=%dx%d TL=%s TR=%s BL=%s BR=%s\n",
        w, h, tl, tr, bl, br))

    local ok, err = pcall(function()
        assert(tl == "red"   , "TL should be red, got "    .. tl)
        assert(tr == "green" , "TR should be green, got "  .. tr)
        assert(bl == "blue"  , "BL should be blue, got "   .. bl)
        assert(br == "yellow", "BR should be yellow, got " .. br)
    end)

    c:kill()
    os.execute("kill -9 " .. pid .. " 2>/dev/null")
    async.wait_for_no_clients(3)

    if not ok then
        runner.done("test-client-content-dmabuf: " .. tostring(err))
    else
        runner.done()
    end
end)
