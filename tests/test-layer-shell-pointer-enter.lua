---------------------------------------------------------------------------
--- Test: wl_pointer.enter delivered when layer surface maps under stationary cursor
--
-- Regression test: a layer-shell surface mapping underneath a stationary
-- cursor must receive wl_pointer.enter synchronously, without requiring the
-- user to move the mouse. The bug (before the fix in commitlayersurfacenotify)
-- was that motionnotify() was never re-run after the new scene node appeared,
-- so the seat kept its old focused_surface and hover/click-through didn't work.
--
-- Verification: test-layer-client writes "entered\n" to a marker file on its
-- wl_pointer.enter callback. The test positions the cursor inside the 100x100
-- top-left-anchored surface area BEFORE the client maps, then spawns the
-- client and asserts the marker file is written.
---------------------------------------------------------------------------

local runner = require("_runner")
local async = require("_async")
local awful = require("awful")

local TEST_LAYER_CLIENT = "./build-test/test-layer-client"

local function file_exists(path)
    local f = io.open(path, "r")
    if not f then return false end
    f:close()
    return true
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

if not file_exists(TEST_LAYER_CLIENT) then
    io.stderr:write("SKIP: test-layer-client not found (run meson compile first)\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local marker = string.format("/tmp/somewm-test-pointer-enter-%d.mark", os.time() * 1000 + math.random(0, 999))
os.remove(marker)

local namespace = "test-pointer-enter"
local layer_pid

runner.run_async(function()
    -- 1. Park the cursor inside the future surface area BEFORE spawning.
    --    --anchor top,left lands the 100x100 surface at (0,0)-(100,100);
    --    (50, 50) is the centre of that box.
    mouse.coords({ x = 50, y = 50 }, true)
    io.stderr:write("[TEST] Cursor parked at (50, 50)\n")

    -- 2. Spawn the layer client.  --keyboard=none avoids keyboard focus stealing.
    local cmd = string.format(
        "%s --namespace %s --keyboard none --anchor top,left --pointer-marker %s",
        TEST_LAYER_CLIENT, namespace, marker)
    io.stderr:write("[TEST] Spawning: " .. cmd .. "\n")
    layer_pid = awful.spawn(cmd)
    assert(type(layer_pid) == "number", "awful.spawn returned: " .. tostring(layer_pid))

    -- 3. Wait for the layer surface to be known to Lua.
    local layer_surf
    local mapped = async.wait_for_condition(function()
        if not layer_surface then return false end
        for _, ls in ipairs(layer_surface.get()) do
            if ls.namespace and ls.namespace == namespace then
                layer_surf = ls
                return ls.mapped
            end
        end
        return false
    end, 5)
    assert(mapped, "layer surface did not map within 5s")
    local geo = layer_surf.geometry
    io.stderr:write(string.format("[TEST] Layer surface mapped at (%d, %d) %dx%d\n",
        geo.x, geo.y, geo.width, geo.height))
    io.stderr:write(string.format("[TEST] Cursor at (%d, %d)\n",
        mouse.coords().x, mouse.coords().y))

    -- 4. Wait for the round-trip: compositor sends wl_pointer.enter, client's
    --    event loop dispatches it, callback writes the marker file.
    local got_enter = async.wait_for_condition(function()
        return file_exists(marker)
    end, 3, 0.05)

    if not got_enter then
        os.execute("kill -9 " .. layer_pid .. " 2>/dev/null")
        os.remove(marker)
        error("wl_pointer.enter was NOT delivered to layer surface under stationary cursor")
    end

    local contents = read_file(marker) or ""
    assert(contents:match("entered"), "marker file exists but content was: " .. contents)
    io.stderr:write("[TEST] PASS: wl_pointer.enter delivered to layer surface\n")

    -- 5. Cleanup.
    os.execute("kill -9 " .. layer_pid .. " 2>/dev/null")
    os.remove(marker)

    runner.done()
end)

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
