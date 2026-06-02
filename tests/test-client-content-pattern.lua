---------------------------------------------------------------------------
--- Pixel-content test for c.content at non-unit screen scale.
---
--- A wl_shm test client renders a 4-quadrant pattern (TL=red, TR=green,
--- BL=blue, BR=yellow) at the compositor's preferred buffer scale. Split
--- is computed from the physical buffer dimensions, so each logical
--- quadrant of c.content should always show its expected color regardless
--- of screen scale.
---
--- The Lua driver samples one pixel near the center of each logical
--- quadrant via FFI to cairo and asserts the dominant color.
---
--- Runs at scale=1 (guards the src==dst fast path) and scale=2 (HiDPI).
--- Exercises the SHM fast path of luaA_client_get_content; the GPU texture
--- path uses identical composite logic but exercising it requires a
--- DMA-BUF client.
---
--- Run: make test-one TEST=tests/test-client-content-pattern.lua
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
int cairo_image_surface_get_width(void *surface);
int cairo_image_surface_get_height(void *surface);
]]

local APP_ID = "content_pattern_test"

-- Resolve which build dir the harness used (./build vs ./build-test) so we
-- find the right binary under both `make test-asan` and `make test-integration`.
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

-- Wait for the C client to have committed at the target scale by polling its
-- marker file. The C client writes the integer scale to
-- /tmp/test-content-pattern-<pid>.scale after every successful commit.
local function wait_for_scale_commit(pid, target_scale, timeout_secs)
    local path = string.format("/tmp/test-content-pattern-%d.scale", pid)
    return async.wait_for_condition(function()
        local f = io.open(path, "r")
        if not f then return false end
        local line = f:read("*l")
        f:close()
        return tonumber(line) == target_scale
    end, timeout_secs or 5, 0.05)
end

-- Read pixel (x, y) from a c.content lightuserdata cairo_surface_t* via FFI.
-- ARGB32 stores pixels as native-endian 32-bit; on little-endian the bytes
-- in memory are B, G, R, A.
local function pixel_rgb(raw_surface, x, y)
    ffi.C.cairo_surface_flush(raw_surface)
    local data   = ffi.C.cairo_image_surface_get_data(raw_surface)
    local stride = ffi.C.cairo_image_surface_get_stride(raw_surface)
    local off = y * stride + x * 4
    return data[off + 2], data[off + 1], data[off + 0]   -- R, G, B
end

local function dominant_color(r, g, b)
    if r > 200 and g <  80 and b <  80 then return "red"    end
    if g > 200 and r <  80 and b <  80 then return "green"  end
    if b > 200 and r <  80 and g <  80 then return "blue"   end
    if r > 200 and g > 200 and b <  80 then return "yellow" end
    return string.format("rgb(%d,%d,%d)", r, g, b)
end

local function run_at_scale(target_scale, pids)
    local s = screen[1]
    s.scale = target_scale
    async.sleep(0.05)   -- let the scale change propagate to outputs

    local pid = awful.spawn({BINARY})
    assert(type(pid) == "number" and pid > 0,
        "Failed to spawn binary: " .. tostring(pid))
    table.insert(pids, pid)

    local c = async.wait_for_client(APP_ID, 5)
    assert(c, "Client never appeared at scale=" .. tostring(target_scale))

    -- Move the client off the scene origin so c.content's scene-tree walk
    -- exercises non-zero buffer positions. A regression here (commit
    -- introducing #539's scene-walk) only manifested when the client was
    -- somewhere other than (0, 0).
    c.floating = true
    local g = c:geometry()
    c:geometry { x = 173, y = 109, width = g.width, height = g.height }
    async.sleep(0.05)

    -- Wait for the buffer at the target scale to actually be committed.
    -- At scale=1 this is the first commit; at scale=2 the C client first
    -- commits at scale=1 (default) then re-renders after preferred_buffer_scale.
    local ok = wait_for_scale_commit(pid, target_scale, 5)
    assert(ok, string.format(
        "C client never committed scale=%d (marker file never matched)", target_scale))

    -- Surface dims should now match logical content dimensions.
    local raw = c.content
    assert(raw, "c.content returned nil at scale=" .. tostring(target_scale))

    local img = gears.surface(raw)
    local w = img:get_width()
    local h = img:get_height()
    assert(w > 4 and h > 4, string.format(
        "c.content surface too small (%dx%d) at scale=%d", w, h, target_scale))

    -- Sample one pixel near the center of each logical quadrant.
    local qx1, qx2 = math.floor(w * 0.25), math.floor(w * 0.75)
    local qy1, qy2 = math.floor(h * 0.25), math.floor(h * 0.75)
    local tl = dominant_color(pixel_rgb(raw, qx1, qy1))
    local tr = dominant_color(pixel_rgb(raw, qx2, qy1))
    local bl = dominant_color(pixel_rgb(raw, qx1, qy2))
    local br = dominant_color(pixel_rgb(raw, qx2, qy2))

    io.stderr:write(string.format(
        "[content-pattern] scale=%s surface=%dx%d TL=%s TR=%s BL=%s BR=%s\n",
        tostring(target_scale), w, h, tl, tr, bl, br))

    assert(tl == "red"   , "TL quadrant should be red, got "    .. tl)
    assert(tr == "green" , "TR quadrant should be green, got "  .. tr)
    assert(bl == "blue"  , "BL quadrant should be blue, got "   .. bl)
    assert(br == "yellow", "BR quadrant should be yellow, got " .. br)

    c:kill()
    async.wait_for_no_clients(3)
end

runner.run_async(function()
    local s = screen[1]
    local original_scale = s.scale
    local pids = {}

    local ok, err = pcall(function()
        run_at_scale(1.0, pids)
        run_at_scale(2.0, pids)
    end)

    -- Always-run cleanup
    s.scale = original_scale
    for _, pid in ipairs(pids) do
        os.execute("kill -9 " .. pid .. " 2>/dev/null")
        os.execute("rm -f /tmp/test-content-pattern-" .. pid .. ".scale")
    end
    for _, c in ipairs(client.get()) do c:kill() end
    async.wait_for_no_clients(3)

    if not ok then
        runner.done("test-client-content-pattern: " .. tostring(err))
    else
        runner.done()
    end
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
