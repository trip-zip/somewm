---------------------------------------------------------------------------
--- Wallpaper service — per-tag wallpaper management with override support.
--
-- Replaces inline wallpaper code in rc.lua with a proper service.
-- Supports per-tag overrides from the shell wallpaper picker, so that
-- the chosen wallpaper persists across tag switches.
--
-- The service does NOT use the service.new() polling pattern because
-- wallpaper changes are event-driven (tag selection + IPC commands),
-- not periodic.
--
-- IPC API (via somewm-client eval):
--   require('fishlive.services.wallpaper').set_override(tag_name, path)
--   require('fishlive.services.wallpaper').clear_override(tag_name)
--   require('fishlive.services.wallpaper').set_main_wallpaper(path)
--   require('fishlive.services.wallpaper').get_overrides_json()
--   require('fishlive.services.wallpaper').get_current()
--
-- @module fishlive.services.wallpaper
-- @author Antonin Fischer (raven2cz) & Claude
-- @copyright 2026 MIT License
---------------------------------------------------------------------------

local awful = require("awful")
local gears = require("gears")
local wibox = require("wibox")
local broker = require("fishlive.broker")

local wallpaper = {}

-- State
wallpaper._overrides = {}         -- { [tag_name] = "/absolute/path.jpg" }
wallpaper._wppath = nil           -- base path: themes/name/wallpapers/
wallpaper._default = "1.jpg"      -- fallback wallpaper filename
wallpaper._initialized = false

--- Apply wallpaper to a screen using awful.wallpaper API (HiDPI-aware).
-- @tparam screen scr The screen object
-- @tparam string path Absolute path to wallpaper image
local function apply_wallpaper(scr, path)
	if not path or not gears.filesystem.file_readable(path) then
		return false
	end

	-- Skip redundant updates
	if scr._current_wallpaper == path then return true end

	awful.wallpaper {
		screen = scr,
		widget = {
			{
				image     = path,
				upscale   = true,
				downscale = true,
				widget    = wibox.widget.imagebox,
			},
			valign = "center",
			halign = "center",
			tiled  = false,
			widget = wibox.container.tile,
		}
	}
	scr._current_wallpaper = path
	return true
end

--- Resolve wallpaper path for a tag.
-- Override takes priority, then theme-based tag-name mapping, then default.
-- @tparam string tag_name The tag name (e.g. "1", "2", ...)
-- @treturn string Absolute path to the wallpaper file
function wallpaper._resolve(tag_name)
	-- 1. Check override
	if wallpaper._overrides[tag_name] then
		local path = wallpaper._overrides[tag_name]
		if gears.filesystem.file_readable(path) then
			return path
		end
		-- Override file disappeared — clear it
		wallpaper._overrides[tag_name] = nil
	end

	-- 2. Theme-based: wppath/tag_name.{jpg,png,webp,jpeg}
	if wallpaper._wppath then
		for _, ext in ipairs({ ".jpg", ".png", ".webp", ".jpeg" }) do
			local path = wallpaper._wppath .. tag_name .. ext
			if gears.filesystem.file_readable(path) then
				return path
			end
		end
	end

	-- 3. Default fallback
	if wallpaper._wppath then
		return wallpaper._wppath .. wallpaper._default
	end

	return nil
end

--- Initialize the wallpaper service for a screen.
-- Call this inside awful.screen.connect_for_each_screen.
-- Replaces the inline wallpaper code that was in rc.lua.
--
-- @tparam screen scr The screen object
-- @tparam string wppath Base wallpaper directory (themes/name/wallpapers/)
-- @tparam[opt="1.jpg"] string default_wallpaper Default fallback filename
function wallpaper.init(scr, wppath, default_wallpaper)
	wallpaper._wppath = wppath
	wallpaper._default = default_wallpaper or "1.jpg"
	wallpaper._initialized = true

	-- Expose wppath for tag_slide animation overlays
	scr._wppath = wppath

	-- Initial wallpaper
	local path = wallpaper._resolve(wallpaper._default:match("(.-)%.") or "1")
	if path then apply_wallpaper(scr, path) end

	-- Pre-cache all wallpapers for tag_slide animation overlays
	if root.wallpaper_cache_preload then
		local paths = {}
		for i = 1, 9 do
			local wp = wppath .. i .. ".jpg"
			if gears.filesystem.file_readable(wp) then
				table.insert(paths, wp)
			end
		end
		if #paths > 0 then root.wallpaper_cache_preload(paths, scr) end
	end

	-- Switch wallpaper on tag selection
	for _, tag in ipairs(scr.tags) do
		tag:connect_signal("property::selected", function(t)
			if t.selected then
				local wp = wallpaper._resolve(t.name)
				if wp then apply_wallpaper(t.screen, wp) end
			end
		end)
	end
end

--- Set a wallpaper override for a tag.
-- The override persists until cleared. On the next tag switch to this tag,
-- the override path is used instead of the theme default.
-- If the tag is currently selected, the wallpaper is applied immediately.
--
-- @tparam string tag_name Tag name (e.g. "1")
-- @tparam string path Absolute path to wallpaper image
function wallpaper.set_override(tag_name, path)
	if not path or path == "" then return end
	wallpaper._overrides[tag_name] = path

	-- Apply immediately if this tag is currently selected on any screen
	for scr in screen do
		local sel = scr.selected_tag
		if sel and sel.name == tag_name then
			apply_wallpaper(scr, path)
		end
	end

	-- Notify shell of change
	broker.emit_signal("data::wallpaper", wallpaper._get_state())
end

--- Clear a wallpaper override for a tag, reverting to theme default.
-- @tparam string tag_name Tag name
function wallpaper.clear_override(tag_name)
	wallpaper._overrides[tag_name] = nil

	-- Revert to theme wallpaper if this tag is currently selected
	for scr in screen do
		local sel = scr.selected_tag
		if sel and sel.name == tag_name then
			local wp = wallpaper._resolve(tag_name)
			if wp then apply_wallpaper(scr, wp) end
		end
	end

	broker.emit_signal("data::wallpaper", wallpaper._get_state())
end

--- Set the main wallpaper (tag "1" override).
-- Convenience function for the shell wallpaper picker.
-- @tparam string path Absolute path to wallpaper image
function wallpaper.set_main_wallpaper(path)
	wallpaper.set_override("1", path)
end

--- Get current wallpaper state as a table.
-- @treturn table { current = path, overrides = {tag=path,...} }
function wallpaper._get_state()
	local current = nil
	local focused = awful.screen.focused()
	if focused then
		current = focused._current_wallpaper
	end
	return {
		current = current or "",
		overrides = wallpaper._overrides,
		wppath = wallpaper._wppath or "",
	}
end

--- Get overrides as JSON string (for IPC).
-- @treturn string JSON representation of override map
function wallpaper.get_overrides_json()
	local parts = {}
	for k, v in pairs(wallpaper._overrides) do
		local ek = k:gsub('\\', '\\\\'):gsub('"', '\\"')
		local ev = v:gsub('\\', '\\\\'):gsub('"', '\\"')
		table.insert(parts, '"' .. ek .. '":"' .. ev .. '"')
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

--- Get the current wallpaper path for the focused screen (for IPC).
-- @treturn string Current wallpaper path or empty string
function wallpaper.get_current()
	local focused = awful.screen.focused()
	return focused and focused._current_wallpaper or ""
end

return wallpaper
