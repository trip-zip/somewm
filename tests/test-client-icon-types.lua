local runner = require("_runner")
local async = require("_async")
local test_client = require("_client")
local surface = require("gears.surface")
local cairo = require("lgi").cairo
local ffi = require("ffi")

ffi.cdef[[
void cairo_surface_flush(void *surface);
unsigned char *cairo_image_surface_get_data(void *surface);
int cairo_image_surface_get_stride(void *surface);
]]

local function pixels(image)
    local width, height = image:get_width(), image:get_height()
    local copy = cairo.ImageSurface.create(cairo.Format.ARGB32, width, height)
    local cr = cairo.Context(copy)
    cr:set_source_surface(image, 0, 0)
    cr:paint()
    ffi.C.cairo_surface_flush(copy._native)
    local data = ffi.C.cairo_image_surface_get_data(copy._native)
    local stride = ffi.C.cairo_image_surface_get_stride(copy._native)
    local rows = {}
    for y = 0, height - 1 do
        rows[#rows + 1] = ffi.string(data + y * stride, width * 4)
    end
    return table.concat(rows)
end

if not test_client.is_available() then
    return runner.skip("no terminal available for test clients")
end

local image = surface.load_uncached(
    "tests/xdg/icons/hicolor/16x16/apps/somewm-test-app-icon.png")
local managed, accepted, rejection
local function manage(c)
    if c.class ~= "icon_types_test" then return end
    accepted, rejection = pcall(function() c.icon = image end)
    if not accepted then
        c.icon = image._native
    end
    managed = c
end

client.connect_signal("request::manage", manage)

runner.run_async(function()
    test_client("icon_types_test")
    local c = async.wait_for_client("icon_types_test", 5)
    client.disconnect_signal("request::manage", manage)
    assert(c and managed == c, "request::manage did not receive the client")
    assert(accepted == false, "LGI surface assignment must raise a Lua error")
    assert(rejection:find("client.icon", 1, true), rejection)
    assert(rejection:find("light userdata", 1, true), rejection)
    assert(rejection:find("userdata", 1, true), rejection)

    local width, height = image:get_width(), image:get_height()
    local expected = pixels(image)
    local function check_icon()
        assert(c.icon, "native surface assignment did not produce an icon")
        local icon = surface.load_uncached(c.icon)
        assert(icon:get_width() == width and icon:get_height() == height)
        assert(pixels(icon) == expected,
            "icon pixels differ from the assigned surface")
    end
    check_icon()

    for _, value in ipairs({ image, newproxy(true), {}, 42, true, "icon",
            function() end }) do
        local ok, err = pcall(function() c.icon = value end)
        assert(not ok, "invalid icon assignment must raise a Lua error")
        assert(err:find("got " .. type(value), 1, true), err)
        check_icon()
    end

    c.icon = nil
    assert(c.icon == nil, "nil must clear the icon")
    runner.done()
end)
