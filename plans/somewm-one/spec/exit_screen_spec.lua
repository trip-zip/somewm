---------------------------------------------------------------------------
--- Tests for fishlive.exit_screen
---------------------------------------------------------------------------

package.path = "./plans/somewm-one/?.lua;./plans/somewm-one/?/init.lua;" .. package.path

-- Stub lgi (rubato needs lgi.GLib for timers)
package.preload["lgi"] = function()
	return {
		GLib = {
			PRIORITY_DEFAULT = 0,
			get_monotonic_time = function() return 0 end,
			timeout_add = function(_, _, cb) return 1 end,
		},
	}
end

-- Stub beautiful
package.preload["beautiful"] = function()
	return {
		bg_normal = "#181818",
		fg_focus = "#d4d4d4",
		fg_urgent = "#e06c75",
		border_color_active = "#e2b55a",
		exit_screen_bg = "#181818dd",
		exit_screen_fg = "#d4d4d4",
		exit_screen_icon = "#e2b55a",
		exit_screen_icon_hover = "#e06c75",
	}
end

package.preload["beautiful.xresources"] = function()
	return { apply_dpi = function(v) return v end }
end

-- Minimal wibox stub
local widget_mt = {
	__index = {
		connect_signal = function() end,
		buttons = function() end,
		setup = function() end,
	},
}
local function make_widget(t)
	t = t or {}
	return setmetatable(t, widget_mt)
end

package.preload["wibox"] = function()
	local wibox_call_mt = {
		__call = function(_, t) return make_widget(t) end,
	}
	return setmetatable({
		widget = setmetatable({
			textbox = setmetatable({}, {
				__call = function(_, t) return make_widget(t) end,
			}),
			textclock = setmetatable({}, {
				__call = function(_, t) return make_widget(t) end,
			}),
			imagebox = setmetatable({}, {
				__call = function(_, t) return make_widget(t) end,
			}),
		}, { __call = function(_, t) return make_widget(t) end }),
		container = {
			background = setmetatable({}, {
				__call = function(_, ...) return make_widget({}) end,
			}),
			margin = setmetatable({}, {
				__call = function(_, ...) return make_widget({ left = 0, right = 0, top = 0, bottom = 0 }) end,
			}),
			place = setmetatable({}, {
				__call = function(_, t) return make_widget(t) end,
			}),
			constraint = setmetatable({}, {
				__call = function(_, t) return make_widget(t) end,
			}),
		},
		layout = {
			fixed = {
				horizontal = { is_layout = true },
				vertical = { is_layout = true },
			},
			stack = { is_layout = true },
		},
	}, wibox_call_mt)
end

-- Minimal stubs for other deps
package.preload["awful"] = function()
	return {
		keygrabber = function(t) return { start = function() end, stop = function() end } end,
		button = function() return {} end,
		screen = { focused = function() return { geometry = { x = 0, y = 0, width = 1920, height = 1080 } } end },
		spawn = { with_shell = function() end },
	}
end

package.preload["gears"] = function()
	return {
		shape = { rounded_rect = function() end },
		table = { join = function(...) return {} end },
		timer = { start_new = function(_, cb) cb() return true end },
		surface = { load_uncached_silently = function(path) return path and {} or nil end },
	}
end

-- =========================================================================

describe("exit_screen", function()
	local es

	before_each(function()
		package.loaded["fishlive.exit_screen"] = nil
		es = require("fishlive.exit_screen")
		es._reset()
	end)

	-- -----------------------------------------------------------------
	-- highlight_label
	-- -----------------------------------------------------------------
	describe("highlight_label", function()
		it("highlights first letter match (case-sensitive start)", function()
			local result = es.highlight_label("Poweroff", "P", "#e2b55a", "#d4d4d4")
			assert.is_truthy(result:find("<b><u>P</u></b>"))
			assert.is_truthy(result:find("#e2b55a"))
		end)

		it("highlights mid-word letter case-insensitively", function()
			local result = es.highlight_label("Refresh", "F", "#e2b55a", "#d4d4d4")
			-- Should find lowercase 'f' at position 3 in "Refresh"
			assert.is_truthy(result:find("<b><u>f</u></b>"))
		end)

		it("preserves text before and after highlighted letter", function()
			local result = es.highlight_label("Refresh", "F", "#acc", "#fff")
			assert.is_truthy(result:find("Re"))
			assert.is_truthy(result:find("resh"))
		end)

		it("returns full label in fg_color when key not found", function()
			local result = es.highlight_label("Lock", "Z", "#acc", "#fff")
			assert.is_falsy(result:find("<b>"))
			assert.is_truthy(result:find("Lock"))
			assert.is_truthy(result:find("#fff"))
		end)

		it("handles first-character match", function()
			local result = es.highlight_label("Exit", "E", "#acc", "#fff")
			assert.is_truthy(result:find("<b><u>E</u></b>"))
			assert.is_truthy(result:find("xit"))
		end)

		it("handles last-character match", function()
			local result = es.highlight_label("Lock", "K", "#acc", "#fff")
			assert.is_truthy(result:find("<b><u>k</u></b>"))
			assert.is_truthy(result:find("Loc"))
		end)

		it("handles single-character label", function()
			local result = es.highlight_label("X", "X", "#acc", "#fff")
			assert.is_truthy(result:find("<b><u>X</u></b>"))
		end)
	end)

	-- -----------------------------------------------------------------
	-- lerp_color
	-- -----------------------------------------------------------------
	describe("lerp_color", function()
		it("returns start color at t=0", function()
			assert.are.equal("#ff0000", es.lerp_color("#ff0000", "#00ff00", 0))
		end)

		it("returns end color at t=1", function()
			assert.are.equal("#00ff00", es.lerp_color("#ff0000", "#00ff00", 1))
		end)

		it("returns midpoint at t=0.5", function()
			local mid = es.lerp_color("#000000", "#ffffff", 0.5)
			-- Should be approximately #808080 (127 or 128 depending on rounding)
			local r = tonumber(mid:sub(2, 3), 16)
			assert.is_true(r >= 127 and r <= 128)
		end)

		it("handles same color", function()
			assert.are.equal("#abcdef", es.lerp_color("#abcdef", "#abcdef", 0.5))
		end)

		it("returns valid hex format", function()
			local result = es.lerp_color("#102030", "#d0e0f0", 0.3)
			assert.is_truthy(result:match("^#%x%x%x%x%x%x$"))
		end)
	end)

	-- -----------------------------------------------------------------
	-- resolve_config
	-- -----------------------------------------------------------------
	describe("resolve_config", function()
		it("uses beautiful values as defaults", function()
			local cfg = es.resolve_config()
			assert.are.equal("#181818dd", cfg.bg_color)
			assert.are.equal("#d4d4d4", cfg.fg_color)
			assert.are.equal("#e2b55a", cfg.icon_color)
			assert.are.equal("#e06c75", cfg.icon_hover)
		end)

		it("opts override beautiful values", function()
			local cfg = es.resolve_config({ bg_color = "#ff0000", icon_color = "#00ff00" })
			assert.are.equal("#ff0000", cfg.bg_color)
			assert.are.equal("#00ff00", cfg.icon_color)
		end)

		it("bg_image defaults to false", function()
			local cfg = es.resolve_config()
			assert.are.equal(false, cfg.bg_image)
		end)

		it("sets rubato animation parameters", function()
			local cfg = es.resolve_config({ anim_duration = 0.4, anim_intro = 0.1, anim_outro = 0.15 })
			assert.are.equal(0.4, cfg.anim_duration)
			assert.are.equal(0.1, cfg.anim_intro)
			assert.are.equal(0.15, cfg.anim_outro)
		end)

		it("has sensible animation defaults", function()
			local cfg = es.resolve_config()
			assert.are.equal(0.25, cfg.anim_duration)
			assert.are.equal(0.08, cfg.anim_intro)
			assert.are.equal(0.08, cfg.anim_outro)
		end)

		it("provides default font values", function()
			local cfg = es.resolve_config()
			assert.is_truthy(cfg.font:find("Geist"))
			assert.is_truthy(cfg.icon_font:find("CommitMono"))
			assert.is_truthy(cfg.title_font:find("Bold"))
		end)
	end)

	-- -----------------------------------------------------------------
	-- _state / _reset
	-- -----------------------------------------------------------------
	describe("state management", function()
		it("_reset clears all state", function()
			es._state.initialized = true
			es._state.cfg = { foo = "bar" }
			es._reset()
			assert.is_false(es._state.initialized)
			assert.is_nil(es._state.exit_wb)
			assert.is_nil(es._state.grabber)
			assert.are.same({}, es._state.cfg)
		end)
	end)
end)
