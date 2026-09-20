---------------------------------------------------------------------------
-- Fake screens that split a physical output must behave like independent
-- AwesomeWM screens: drawins reserve their workarea, clients remain visible
-- on selected tags, and tag changes arrange the fake screen.
---------------------------------------------------------------------------

local awful = require("awful")
local runner = require("_runner")
local utils = require("_utils")
local ffi = require("ffi")

ffi.cdef[[
int cairo_image_surface_get_width(void *surface);
]]

local function find_client_binary()
    local somewm = os.getenv("SOMEWM") or "./build-test/somewm"
    local build_dir = somewm:match("^(.*)/somewm$") or "./build-test"
    for _, candidate in ipairs({
        build_dir .. "/test-fullscreen-client",
        "./build/test-fullscreen-client",
        "./build-test/test-fullscreen-client",
    }) do
        local file = io.open(candidate, "r")
        if file then
            file:close()
            return candidate
        end
    end
end

local client_binary = find_client_binary()
if not client_binary then
    io.stderr:write("SKIP: test-fullscreen-client not found (run make build-test)\n")
    io.stderr:write("Test finished successfully.\n")
    awesome.quit()
    return
end

local physical = screen.primary
local original_geometry = physical.geometry
local fake
local middle
local bar
local tag1
local tag2
local test_client
local client_pid
local expected_workarea_y
local original_scale

local steps = {
    function()
        original_scale = physical.scale
        physical.scale = 2.0
        return true
    end,

    function(count)
        if physical.scale ~= 2.0 and count < 20 then return nil end
        assert(physical.scale == 2.0, "physical output did not accept scale=2")

        original_geometry = physical.geometry
        local viewport_width = math.floor(original_geometry.width / 3)
        assert(viewport_width > 0, "physical output is too narrow to split")

        physical:fake_resize(
            original_geometry.x,
            original_geometry.y,
            viewport_width,
            original_geometry.height
        )
        middle = screen.fake_add(
            original_geometry.x + viewport_width,
            original_geometry.y,
            viewport_width,
            original_geometry.height
        )
        fake = screen.fake_add(
            original_geometry.x + viewport_width * 2,
            original_geometry.y,
            original_geometry.width - viewport_width * 2,
            original_geometry.height
        )
        assert(middle and middle.valid and fake and fake.valid,
            "screen.fake_add failed")

        tag1 = fake.tags[1]
        assert(tag1, "fake screen did not receive its initial tag")
        tag1.layout = awful.layout.suit.tile
        tag1:view_only()
        tag2 = awful.tag.add("fake-2", {
            screen = fake,
            layout = awful.layout.suit.tile,
        })

        bar = awful.wibar {
            position = "top",
            screen = fake,
            height = 24,
        }
        return true
    end,

    function(count)
        local geometry = bar:geometry()
        local surface = bar.drawable.surface
        local surface_width = surface and ffi.C.cairo_image_surface_get_width(surface)
        local expected_surface_width = math.floor(geometry.width * physical.scale)
        expected_workarea_y = geometry.y + geometry.height

        if bar.screen ~= fake or fake.workarea.y ~= expected_workarea_y or
                surface_width ~= expected_surface_width then
            if count < 20 then return nil end
        end

        assert(bar.screen == fake,
            "drawin on the fake half was assigned to the physical screen")
        assert(fake.workarea.y == expected_workarea_y, string.format(
            "fake workarea starts at %d, expected %d below its wibar",
            fake.workarea.y, expected_workarea_y))
        assert(fake.workarea.x == fake.geometry.x,
            "fake workarea lost its horizontal viewport")
        assert(surface_width == expected_surface_width,
            string.format("fake-screen wibar surface is %s pixels wide, expected %s",
                tostring(surface_width), tostring(expected_surface_width)))
        return true
    end,

    function(count)
        -- Re-applying drawable geometry calls drawable_get_scale(), separate
        -- from the drawin creation path checked above.
        local geometry = bar.drawable:geometry()
        bar.drawable:geometry(geometry)

        local surface = bar.drawable.surface
        local surface_width = surface and ffi.C.cairo_image_surface_get_width(surface)
        local expected_surface_width = math.floor(geometry.width * physical.scale)
        if surface_width ~= expected_surface_width and count < 20 then
            return nil
        end
        assert(surface_width == expected_surface_width,
            string.format("fake-screen drawable surface is %s pixels wide, expected %s",
                tostring(surface_width), tostring(expected_surface_width)))
        return true
    end,

    function(count)
        if count == 1 then
            client_pid = awful.spawn(client_binary)
        end
        test_client = utils.find_client_by_class("fullscreen_test")
        if not test_client then return nil end

        test_client:move_to_screen(fake)
        test_client:move_to_tag(tag1)
        test_client.floating = false
        return true
    end,

    function(count)
        if test_client.screen ~= fake or not test_client:isvisible() then
            if count < 20 then return nil end
        end
        assert(test_client.screen == fake,
            "client did not retain the fake screen")
        assert(test_client:isvisible(),
            "client on the selected fake-screen tag is not visible")

        test_client:move_to_tag(tag2)
        assert(not test_client:isvisible(),
            "client on an unselected fake-screen tag is visible")
        return true
    end,

    function()
        -- Put the hidden client where a missing arrange call cannot satisfy the
        -- final geometry assertion by accident.
        test_client:geometry {
            x = fake.geometry.x,
            y = fake.geometry.y,
            width = 100,
            height = 100,
        }
        tag2:view_only()
        return true
    end,

    function(count)
        local geometry = test_client:geometry()
        if (not test_client:isvisible() or geometry.y < fake.workarea.y) and
                count < 20 then
            return nil
        end

        assert(test_client:isvisible(),
            "client did not become visible after selecting its fake-screen tag")
        assert(fake.workarea.y == expected_workarea_y, string.format(
            "tag switch reset fake workarea to %d, expected %d",
            fake.workarea.y, expected_workarea_y))
        assert(geometry.y >= fake.workarea.y,
            "tag switch did not arrange the client below the fake-screen wibar")
        return true
    end,

    function(count)
        if count == 1 then
            if test_client and test_client.valid then test_client:kill() end
            if client_pid then awesome.kill(client_pid, 15) end
        end
        if #client.get() > 0 and count < 20 then return nil end

        -- Expand the physical screen before removing the fake viewport, then
        -- verify the visible wibar no longer points at an invalid screen.
        physical:fake_resize(
            original_geometry.x,
            original_geometry.y,
            original_geometry.width,
            original_geometry.height
        )
        if fake and fake.valid then fake:fake_remove() end
        assert(bar.screen == physical and bar.screen.valid,
            "fake_remove left the wibar assigned to an invalid screen")
        if middle and middle.valid then middle:fake_remove() end
        if bar then bar.visible = false end
        physical.scale = original_scale
        return true
    end,
}

runner.run_steps(steps, { kill_clients = false })

-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
