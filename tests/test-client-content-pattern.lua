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
--- Runs at scale=1, at scale=2 (HiDPI), and once more at scale=1 with the
--- client attaching a transparent shadow margin around a smaller xdg window
--- geometry, the way a client-side-decorated app does. Eight more runs
--- commit the buffer with each wl_surface.set_buffer_transform, which
--- permutes the on-screen quadrants; c.content must permute with them.
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
    return data[off + 2], data[off + 1], data[off + 0], data[off + 3]
end

-- Re-fetch c.content until every quadrant sample is opaque. A commit that has
-- landed in the marker file has not necessarily reached the scene graph, and
-- the geometry change above can retrigger one, so a capture taken too early
-- comes back part transparent. Gates on paintedness only, never on colour, so
-- a genuinely wrong orientation still fails rather than spinning.
local function content_when_painted(c, timeout_secs)
    local raw
    async.wait_for_condition(function()
        raw = c.content
        if not raw then return false end
        -- Dimensions via FFI, not gears.surface: an lgi wrapper owns the
        -- surface and would destroy it here, leaving the caller a dangling
        -- pointer.
        local w = ffi.C.cairo_image_surface_get_width(raw)
        local h = ffi.C.cairo_image_surface_get_height(raw)
        if w <= 4 or h <= 4 then return false end
        for _, p in ipairs({{0.25, 0.25}, {0.75, 0.25}, {0.25, 0.75}, {0.75, 0.75}}) do
            local _, _, _, a = pixel_rgb(raw, math.floor(w * p[1]), math.floor(h * p[2]))
            if a < 200 then return false end
        end
        return true
    end, timeout_secs or 5, 0.02)
    return raw
end

local function dominant_color(r, g, b)
    if r > 200 and g <  80 and b <  80 then return "red"    end
    if g > 200 and r <  80 and b <  80 then return "green"  end
    if b > 200 and r <  80 and g <  80 then return "blue"   end
    if r > 200 and g > 200 and b <  80 then return "yellow" end
    return string.format("rgb(%d,%d,%d)", r, g, b)
end

-- On-screen quadrant order per wl_surface.set_buffer_transform. Each row was
-- read off a grim capture of the compositor's own output, so the expectations
-- are independent of how root.c builds its matrices.
local TRANSFORM_QUADRANTS = {
    [0] = {"red",    "green",  "blue",   "yellow"},
    [1] = {"blue",   "red",    "yellow", "green"},
    [2] = {"yellow", "blue",   "green",  "red"},
    [3] = {"green",  "yellow", "red",    "blue"},
    [4] = {"green",  "red",    "yellow", "blue"},
    [5] = {"red",    "blue",   "green",  "yellow"},
    [6] = {"blue",   "yellow", "red",    "green"},
    [7] = {"yellow", "green",  "blue",   "red"},
}
local CORNERS = {"TL", "TR", "BL", "BR"}

-- Spawned client pids, drained by the cleanup block at the end.
local pids = {}

local function run_case(args)
    local s = screen[1]
    local margin, transform = args.margin, args.transform
    if s.scale ~= args.scale then
        s.scale = args.scale
        async.sleep(0.05)   -- let the scale change propagate to outputs
    end

    local cmd = {BINARY}
    if margin then
        table.insert(cmd, "--margin")
        table.insert(cmd, tostring(margin))
    end
    if transform then
        table.insert(cmd, "--transform")
        table.insert(cmd, tostring(transform))
    end
    local pid = awful.spawn(cmd)
    assert(type(pid) == "number" and pid > 0,
        "Failed to spawn binary: " .. tostring(pid))
    table.insert(pids, pid)

    local c = async.wait_for_client(APP_ID, 5)
    assert(c, "Client never appeared at scale=" .. tostring(args.scale))

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
    local ok = wait_for_scale_commit(pid, args.scale, 5)
    assert(ok, string.format(
        "C client never committed scale=%d (marker file never matched)", args.scale))

    -- Surface dims should now match logical content dimensions.
    local raw = content_when_painted(c, 5)
    assert(raw, "c.content returned nil at scale=" .. tostring(args.scale))

    local img = gears.surface(raw)
    local w = img:get_width()
    local h = img:get_height()
    assert(w > 4 and h > 4, string.format(
        "c.content surface too small (%dx%d) at scale=%d", w, h, args.scale))

    -- Sample one pixel near the center of each logical quadrant.
    local qx1, qx2 = math.floor(w * 0.25), math.floor(w * 0.75)
    local qy1, qy2 = math.floor(h * 0.25), math.floor(h * 0.75)
    local tl = dominant_color(pixel_rgb(raw, qx1, qy1))
    local tr = dominant_color(pixel_rgb(raw, qx2, qy1))
    local bl = dominant_color(pixel_rgb(raw, qx1, qy2))
    local br = dominant_color(pixel_rgb(raw, qx2, qy2))

    local want = TRANSFORM_QUADRANTS[transform or 0]
    assert(want, "no expected quadrants for transform " .. tostring(transform))

    io.stderr:write(string.format(
        "[content-pattern] scale=%s margin=%s transform=%s surface=%dx%d TL=%s TR=%s BL=%s BR=%s\n",
        tostring(args.scale), tostring(margin), tostring(transform),
        w, h, tl, tr, bl, br))

    for i, got in ipairs({tl, tr, bl, br}) do
        assert(got == want[i], string.format(
            "%s quadrant should be %s, got %s (transform=%s)",
            CORNERS[i], want[i], got, tostring(transform)))
    end

    if margin then
        -- The shadow margin must be cropped out, not squeezed into the
        -- content rect, so the very corner is pattern rather than the
        -- transparent ring.
        local corner = dominant_color(pixel_rgb(raw, 1, 1))
        assert(corner == want[1],
            "margin run: pixel (1,1) should be " .. want[1] .. ", got " .. corner)
    end

    c:kill()
    async.wait_for_no_clients(3)
end

runner.run_async(function()
    local s = screen[1]
    local original_scale = s.scale

    local ok, err = pcall(function()
        run_case { scale = 1.0 }
        run_case { scale = 2.0 }
        run_case { scale = 1.0, margin = 40 }
        for t = 1, 7 do
            run_case { scale = 1.0, transform = t }
        end
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
