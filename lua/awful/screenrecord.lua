---------------------------------------------------------------------------
--- Screen recording module for somewm.
--
-- Native video recording using built-in libavcodec/libavformat encoding.
-- No external tools required.
--
-- Basic usage
-- ===========
--
--    -- Record entire screen
--    local rec = awful.screenrecord{}
--    rec:start()
--    -- ... later ...
--    rec:stop()
--
-- Record specific screen
-- ======================
--
--    awful.screenrecord {
--        screen = screen.primary,
--        format = "mp4"
--    }:start()
--
-- Interactive region selection
-- ============================
--
--    local rec = awful.screenrecord { interactive = true }
--    rec:connect_signal("file::saved", function(_, path)
--        naughty.notify { title = "Recording saved", text = path }
--    end)
--    rec:start()
--
-- @author somewm contributors
-- @copyright 2024 somewm contributors
-- @classmod awful.screenrecord
---------------------------------------------------------------------------

local capi = {
    root         = root,
    screen       = screen,
    mousegrabber = mousegrabber
}

local gears     = require("gears")
local beautiful = require("beautiful")
local wibox     = require("wibox")
local abutton   = require("awful.button")
local akey      = require("awful.key")
local akgrabber = require("awful.keygrabber")
local gtimer    = require("gears.timer")
local glib      = require("lgi").GLib
local datetime  = glib.DateTime
local timezone  = glib.TimeZone

local module = { mt = {} }

-- Generate a date string
local function get_date(format)
    return datetime.new_now(timezone.new_local()):format(format)
end

-- Validation functions
local screenrecord_validation = {}

function screenrecord_validation.directory(directory)
    if string.find(directory, "^~/") then
        directory = string.gsub(directory, "^~/",
                              string.gsub(os.getenv("HOME"), "/*$", "/", 1))
    elseif string.find(directory, "^[^/]") then
        directory = string.gsub(os.getenv("HOME"), "/*$", "/", 1) .. directory
    end

    directory = string.gsub(directory, '/*$', '/', 1)
    if directory:sub(-1) ~= "/" then
        directory = directory .. "/"
    end

    if gears.filesystem.is_dir(directory) and not gears.filesystem.dir_writable(directory) then
        gears.debug.print_error("`"..directory.. "` is not writable.")
    end

    return directory
end

function screenrecord_validation.prefix(prefix)
    if prefix:match("[/.]") then
        gears.debug.print_error("`"..prefix..
            "` is not a valid prefix because it contains `/` or `.`")
    end
    return prefix
end

function screenrecord_validation.geometry(geo)
    for _, part in ipairs {"x", "y", "width", "height" } do
        if not geo[part] then
            gears.debug.print_error("The screenrecord geometry must be a table with "..
                "`x`, `y`, `width` and `height`"
            )
            break
        end
    end
    return geo
end

function screenrecord_validation.screen(scr)
    return capi.screen[scr]
end

function screenrecord_validation.format(fmt)
    local valid = { mp4 = true, webm = true, gif = true, mkv = true }
    if not valid[fmt] then
        gears.debug.print_error("Invalid format `"..tostring(fmt).."`. Use mp4, webm, gif, or mkv.")
        return "mp4"
    end
    return fmt
end

function screenrecord_validation.framerate(fps)
    fps = tonumber(fps) or 30
    if fps < 1 or fps > 120 then
        gears.debug.print_error("Framerate must be between 1 and 120")
        return 30
    end
    return fps
end

-- Generate filename
local function make_file_name(self)
    local date_time = get_date(self.date_format)
    return self.prefix .. date_time .. "." .. self.format
end

local function make_file_path(self)
    return self.directory .. (self._private.file_name or make_file_name(self))
end

--- The recording frame color for interactive mode.
-- @beautiful beautiful.screenrecord_frame_color
-- @tparam[opt="#ff0000"] color screenrecord_frame_color

--- The recording frame shape for interactive mode.
-- @beautiful beautiful.screenrecord_frame_shape
-- @tparam[opt=gears.shape.rectangle] shape screenrecord_frame_shape

--- Emitted when recording starts.
-- @signal recording::start
-- @tparam awful.screenrecord self

--- Emitted when recording stops.
-- @signal recording::stop
-- @tparam awful.screenrecord self

--- Emitted every second during recording.
-- @signal recording::tick
-- @tparam awful.screenrecord self
-- @tparam number elapsed Seconds elapsed

--- Emitted when recording file is saved.
-- @signal file::saved
-- @tparam awful.screenrecord self
-- @tparam string file_path Path to saved file

--- Emitted when recording fails.
-- @signal recording::error
-- @tparam awful.screenrecord self
-- @tparam string reason Error message

--- Emitted when interactive snipping starts.
-- @signal snipping::start
-- @tparam awful.screenrecord self

--- Emitted when interactive snipping succeeds.
-- @signal snipping::success
-- @tparam awful.screenrecord self

--- Emitted when interactive snipping is cancelled.
-- @signal snipping::cancelled
-- @tparam awful.screenrecord self
-- @tparam string reason Cancellation reason

-- Interactive mode: show selection frame
local function show_frame(self)
    local col = self._private.frame_color
          or beautiful.screenrecord_frame_color
          or "#ff0000"

    local shape = self.frame_shape
        or beautiful.screenrecord_frame_shape
        or gears.shape.rectangle

    local w, h = capi.root.size()

    self._private.selection_widget = wibox.widget {
        border_width  = 3,
        border_color  = col,
        shape         = shape,
        color         = "transparent",
        visible       = false,
        widget        = wibox.widget.separator
    }
    self._private.selection_widget.point = {x=0, y=0}
    self._private.selection_widget.fit = function() return 0,0 end

    self._private.canvas_widget = wibox.widget {
        widget = wibox.layout.manual
    }

    self._private.canvas_widget:add(self._private.selection_widget)

    self._private.frame = wibox {
        ontop   = true,
        x       = 0,
        y       = 0,
        width   = w,
        height  = h,
        widget  = self._private.canvas_widget,
        visible = true,
        bg      = "#00000044",
    }
end

-- Interactive mode: start region selection
local function start_snipping(self)
    self._private.mg_first_pnt = {}

    local accept_buttons, reject_buttons = {}, {}

    for _, btn in ipairs(self.accept_buttons) do
        accept_buttons[btn.button] = true
    end
    for _, btn in ipairs(self.reject_buttons) do
        reject_buttons[btn.button] = true
    end

    local pressed = false

    show_frame(self)

    local function mg_callback(mouse_data)
        local accept, reject = false, false

        for btn, status in pairs(mouse_data.buttons) do
            accept = accept or (status and accept_buttons[btn])
            reject = reject or (status and reject_buttons[btn])
        end

        if reject then
            self:cancel("mouse_button")
            return false
        elseif pressed then
            local min_x = math.min(self._private.mg_first_pnt[1], mouse_data.x)
            local max_x = math.max(self._private.mg_first_pnt[1], mouse_data.x)
            local min_y = math.min(self._private.mg_first_pnt[2], mouse_data.y)
            local max_y = math.max(self._private.mg_first_pnt[2], mouse_data.y)

            self._private.selected_geometry = {
                x       = min_x,
                y       = min_y,
                width   = max_x - min_x,
                height  = max_y - min_y,
            }
            self:emit_signal("property::selected_geometry", self._private.selected_geometry)

            if not accept then
                -- Mouse released - accept selection
                return self:_accept_selection()
            else
                -- Update visual
                self._private.selection_widget.point.x = min_x
                self._private.selection_widget.point.y = min_y
                self._private.selection_widget.fit = function()
                    return self._private.selected_geometry.width, self._private.selected_geometry.height
                end
                self._private.selection_widget:emit_signal("widget::layout_changed")
                self._private.canvas_widget:emit_signal("widget::redraw_needed")
            end
        elseif accept then
            pressed = true
            self._private.selection_widget.visible = true
            self._private.selection_widget.point.x = mouse_data.x
            self._private.selection_widget.point.y = mouse_data.y
            self._private.mg_first_pnt[1] = mouse_data.x
            self._private.mg_first_pnt[2] = mouse_data.y
        end

        return true
    end

    self.keygrabber:start()
    capi.mousegrabber.run(mg_callback, self.cursor)
    self:emit_signal("snipping::start")
end

-- Accept interactive selection and start recording
function module:_accept_selection()
    local new_geo = self._private.selected_geometry
    local min_size = self.minimum_size

    if not new_geo then
        self:cancel("no_selection")
        return false
    end

    if min_size and (new_geo.width < min_size.width or new_geo.height < min_size.height) then
        self:cancel("too_small")
        return false
    end

    -- Clean up frame
    if self._private.frame then
        self._private.frame.visible = false
        self._private.frame = nil
    end
    self._private.mg_first_pnt = nil
    self.keygrabber:stop()
    capi.mousegrabber.stop()

    -- Set geometry and start recording
    self._private.geometry = new_geo
    self:emit_signal("snipping::success")
    self:_start_recording()

    return true
end

-- Default property values
local defaults = {
    prefix                  = "Recording-",
    directory               = screenrecord_validation.directory(os.getenv("HOME")),
    cursor                  = "crosshair",
    date_format             = "%Y%m%d%H%M%S",
    format                  = "mp4",
    framerate               = 30,
    interactive             = false,
    reject_buttons          = {abutton({}, 3)},
    accept_buttons          = {abutton({}, 1)},
    reject_keys             = {akey({}, "Escape")},
    accept_keys             = {akey({}, "Return")},
    minimum_size            = {width = 10, height = 10},
}

-- Property accessors
for _, prop in ipairs { "frame_color", "geometry", "screen", "date_format",
                        "prefix", "directory", "file_path", "file_name",
                        "interactive", "reject_buttons", "accept_buttons", "cursor",
                        "reject_keys", "accept_keys", "frame_shape", "minimum_size",
                        "format", "framerate", "duration" } do
    module["set_"..prop] = function(self, value)
        self._private[prop] = screenrecord_validation[prop]
            and screenrecord_validation[prop](value) or value
        self:emit_signal("property::"..prop, value)
    end

    module["get_"..prop] = function(self)
        return self._private[prop] or defaults[prop]
    end
end

function module:get_selected_geometry()
    return self._private.selected_geometry
end

function module:get_file_path()
    return self._private.file_path or make_file_path(self)
end

function module:get_file_name()
    return self._private.file_name or make_file_name(self)
end

--- Check if currently recording.
-- @property is_recording
-- @tparam boolean is_recording
-- @readonly
function module:get_is_recording()
    return capi.root.screenrecord_is_recording()
end

--- Get elapsed recording time in seconds.
-- @property elapsed
-- @tparam number elapsed
-- @readonly
function module:get_elapsed()
    return capi.root.screenrecord_elapsed()
end

function module:get_keygrabber()
    if self._private.keygrabber then return self._private.keygrabber end

    self._private.keygrabber = akgrabber {
        stop_key = self.reject_buttons
    }
    self._private.keygrabber:connect_signal("keybinding::triggered", function(_, key, event)
        if event == "press" then return end
        if self._private.accept_keys_set and self._private.accept_keys_set[key] then
            self:_accept_selection()
        elseif self._private.reject_keys_set and self._private.reject_keys_set[key] then
            self:cancel("key")
        end
    end)

    -- Setup key sets
    self._private.accept_keys_set = {}
    self._private.reject_keys_set = {}
    for _, key in ipairs(self.accept_keys) do
        self._private.keygrabber:add_keybinding(key)
        self._private.accept_keys_set[key] = true
    end
    for _, key in ipairs(self.reject_keys) do
        self._private.keygrabber:add_keybinding(key)
        self._private.reject_keys_set[key] = true
    end

    return self._private.keygrabber
end

-- Internal: actually start the recording process
function module:_start_recording()
    if self.is_recording then
        return
    end

    local file_path = self.file_path
    local geo = self._private.geometry or {}

    -- Build config for C backend
    local config = {
        path = file_path,
        x = geo.x or 0,
        y = geo.y or 0,
        width = geo.width or 0,
        height = geo.height or 0,
        framerate = self.framerate,
        format = self.format,
    }

    -- Handle screen property
    if self._private.screen then
        local scr = self._private.screen
        config.x = scr.geometry.x
        config.y = scr.geometry.y
        config.width = scr.geometry.width
        config.height = scr.geometry.height
    end

    -- Start recording via C backend
    local ok, err = capi.root.screenrecord_start(config)
    if not ok then
        self:emit_signal("recording::error", err or "Failed to start recording")
        return
    end

    self._private.is_recording = true
    self._private.file_path = file_path

    -- Start frame capture timer
    local frame_interval = 1.0 / self.framerate
    self._private.capture_timer = gtimer {
        timeout = frame_interval,
        callback = function()
            if capi.root.screenrecord_is_recording() then
                capi.root.screenrecord_capture_frame()
            end
        end
    }
    self._private.capture_timer:start()

    -- Start elapsed timer (for signals)
    self._private.elapsed_timer = gtimer {
        timeout = 1,
        callback = function()
            local elapsed = capi.root.screenrecord_elapsed()
            self:emit_signal("recording::tick", elapsed)

            -- Check duration limit
            if self.duration and elapsed >= self.duration then
                self:stop()
            end
        end
    }
    self._private.elapsed_timer:start()

    self:emit_signal("recording::start")
end

--- Start recording.
-- If interactive mode is enabled, first allows region selection.
-- @method start
-- @noreturn
function module:start()
    if self.is_recording then
        return
    end

    if self.interactive then
        start_snipping(self)
    else
        self:_start_recording()
    end
end

--- Stop recording and save file.
-- @method stop
-- @noreturn
-- @emits recording::stop
-- @emits file::saved
function module:stop()
    if not self.is_recording then
        return
    end

    self:emit_signal("recording::stop")

    -- Stop timers
    if self._private.capture_timer then
        self._private.capture_timer:stop()
        self._private.capture_timer = nil
    end
    if self._private.elapsed_timer then
        self._private.elapsed_timer:stop()
        self._private.elapsed_timer = nil
    end

    -- Stop recording via C backend
    local ok, path = capi.root.screenrecord_stop()
    if ok then
        self:emit_signal("file::saved", path or self._private.file_path)
    end

    self._private.is_recording = false
end

--- Toggle recording (start if stopped, stop if recording).
-- @method toggle
-- @noreturn
function module:toggle()
    if self.is_recording then
        self:stop()
    else
        self:start()
    end
end

--- Cancel recording without saving.
-- @method cancel
-- @tparam[opt] string reason Cancellation reason
-- @noreturn
-- @emits snipping::cancelled
function module:cancel(reason)
    -- Clean up interactive mode
    if self._private.frame then
        self._private.frame.visible = false
        self._private.frame = nil
    end
    self._private.mg_first_pnt = nil
    if self._private.keygrabber then
        self._private.keygrabber:stop()
    end
    capi.mousegrabber.stop()

    -- Stop timers
    if self._private.capture_timer then
        self._private.capture_timer:stop()
        self._private.capture_timer = nil
    end
    if self._private.elapsed_timer then
        self._private.elapsed_timer:stop()
        self._private.elapsed_timer = nil
    end

    -- Cancel recording via C backend
    capi.root.screenrecord_cancel()

    self._private.is_recording = false
    self:emit_signal("snipping::cancelled", reason or "cancel_called")
end

--- Screen recording constructor.
-- @constructorfct awful.screenrecord
-- @tparam[opt={}] table args
-- @tparam[opt] string args.directory Save directory
-- @tparam[opt] string args.prefix Filename prefix
-- @tparam[opt] string args.file_path Override full path
-- @tparam[opt] string args.file_name Override filename
-- @tparam[opt] string args.date_format Date format for filename
-- @tparam[opt] screen args.screen Target screen
-- @tparam[opt] table args.geometry Target region {x,y,width,height}
-- @tparam[opt] boolean args.interactive Enable region selection
-- @tparam[opt] string args.format Output format (mp4, webm, gif, mkv)
-- @tparam[opt] number args.framerate FPS (1-120)
-- @tparam[opt] number args.duration Max recording duration in seconds

local function new(_, args)
    args = (type(args) == "table" and args) or {}
    local self = gears.object({
        enable_auto_signals = true,
        enable_properties   = true
    })

    self._private = {}
    gears.table.crush(self, module, true)
    gears.table.crush(self, args)

    return self
end

return setmetatable(module, {__call = new})
-- vim: filetype=lua:expandtab:shiftwidth=4:tabstop=8:softtabstop=4:textwidth=80
