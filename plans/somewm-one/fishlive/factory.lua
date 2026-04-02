---------------------------------------------------------------------------
--- Component factory — creates wibar widgets with theme fallback.
--
-- Two-level resolution:
--   1. themes/{theme_name}/components/{name}.lua  (themed override)
--   2. fishlive/components/{name}.lua             (standard)
--
-- Each component module must export: create(screen, config) -> widget
--
-- @module fishlive.factory
-- @author Antonin Fischer (raven2cz) & Claude
-- @copyright 2026 MIT License
---------------------------------------------------------------------------

local beautiful = require("beautiful")
local wibox = require("wibox")

local factory = {}

-- Resolved module cache (avoid repeated pcall/require)
local _cache = {}

--- Resolve a component module by name.
-- @tparam string name Component name (e.g. "cpu", "volume")
-- @treturn table|nil The component module, or nil
local function resolve(name)
	if _cache[name] then
		return _cache[name]
	end

	-- Level 1: themed override
	local theme_name = beautiful.theme_name or "default"
	local themed_path = "themes." .. theme_name .. ".components." .. name
	local ok, mod = pcall(require, themed_path)
	if ok and type(mod) == "table" and mod.create then
		_cache[name] = mod
		return mod
	end

	-- Level 2: standard component
	local standard_path = "fishlive.components." .. name
	ok, mod = pcall(require, standard_path)
	if ok and type(mod) == "table" and mod.create then
		_cache[name] = mod
		return mod
	end

	return nil
end

--- Create a component widget.
--
-- @tparam string name Component name (e.g. "cpu", "volume")
-- @param screen Screen object (optional, for DPI/geometry)
-- @tparam table config Extra configuration (optional)
-- @treturn widget The created wibox widget, or error placeholder
function factory.create(name, screen, config)
	local mod = resolve(name)

	if not mod then
		-- Return visible error widget instead of crashing
		local err = wibox.widget.textbox()
		err.markup = string.format(
			'<span color="#f38ba8">[%s?]</span>', name)
		io.stderr:write(string.format(
			"[factory] component not found: %s\n", name))
		return err
	end

	local ok, widget = pcall(mod.create, screen, config or {})
	if not ok then
		local err = wibox.widget.textbox()
		err.markup = string.format(
			'<span color="#f38ba8">[%s!]</span>', name)
		io.stderr:write(string.format(
			"[factory] component create error (%s): %s\n", name, widget))
		return err
	end

	return widget
end

--- List all available component names (for debug/introspection).
-- @treturn table Array of component names
function factory.list()
	local names = {}
	for name in pairs(_cache) do
		names[#names + 1] = name
	end
	return names
end

--- Clear module cache (for testing or theme hot-reload).
function factory._reset()
	_cache = {}
end

return factory
