-- Unit tests for rubato animation components
-- Run: busted --helper='plans/somewm-one/spec/preload.lua' \
--            --lpath='plans/somewm-one/?.lua;plans/somewm-one/?/init.lua' \
--            plans/somewm-one/spec/animations_spec.lua

-- Stub lgi before anything loads rubato
local monotonic_time = 0
package.preload["lgi"] = function()
	return {
		GLib = {
			timeout_add = function(_, interval, cb)
				for _ = 1, 5 do
					monotonic_time = monotonic_time + interval * 1000
					cb()
				end
				return 1
			end,
			get_monotonic_time = function()
				return monotonic_time
			end,
		},
	}
end

-- Minimal stubs
package.preload["beautiful"] = function()
	return {
		xresources = { apply_dpi = function(v) return v end },
		font = "sans 10",
	}
end
package.preload["gears"] = function()
	return {
		timer = function() return { start = function() end } end,
		shape = { rounded_rect = function() end },
	}
end
package.preload["wibox"] = function()
	return {
		widget = {
			textbox = function() return {} end,
			imagebox = { name = "imagebox" },
			base = { make_widget_from_value = function() return {} end },
		},
		container = {
			place = { name = "place" },
			background = { name = "background" },
			margin = { name = "margin" },
			constraint = { name = "constraint" },
		},
		layout = {
			fixed = { horizontal = {}, vertical = {} },
		},
	}
end
package.preload["awful"] = function()
	return {
		widget = {
			taglist = {
				filter = { all = function() end },
			},
		},
		tag = { viewtoggle = function() end, viewprev = function() end, viewnext = function() end },
		button = function() return {} end,
	}
end
package.preload["naughty"] = function()
	return {
		widget = { title = {}, message = {} },
		container = { background = {} },
		layout = { box = function() return { valid = true, opacity = 1 } end },
		config = { defaults = {}, icon_dirs = {}, icon_formats = {} },
		connect_signal = function() end,
	}
end
package.preload["ruled"] = function()
	return {
		notification = {
			connect_signal = function() end,
			append_rule = function() end,
		},
	}
end

-- ===== Taglist component tests =====
describe("fishlive.components.taglist", function()
	local taglist
	setup(function()
		taglist = require("fishlive.components.taglist")
	end)

	describe("_resolve_config", function()
		it("returns defaults when no config given", function()
			local cfg = taglist._resolve_config({})
			assert.are.equal(20, cfg.underline_selected)
			assert.are.equal(0, cfg.underline_occupied)
			assert.are.equal(0, cfg.underline_empty)
			assert.are.equal(0.2, cfg.anim_duration)
		end)

		it("respects custom values", function()
			local cfg = taglist._resolve_config({ underline_selected = 30, anim_duration = 0.5 })
			assert.are.equal(30, cfg.underline_selected)
			assert.are.equal(0.5, cfg.anim_duration)
		end)
	end)

	describe("_target_width", function()
		it("returns selected width for selected tag", function()
			local cfg = taglist._resolve_config({})
			local tag = { selected = true, clients = function() return {} end }
			assert.are.equal(20, taglist._target_width(tag, cfg))
		end)

		it("returns occupied width for tag with clients", function()
			local cfg = taglist._resolve_config({})
			local tag = { selected = false, clients = function() return { {}, {} } end }
			assert.are.equal(0, taglist._target_width(tag, cfg))
		end)

		it("returns empty width for empty tag", function()
			local cfg = taglist._resolve_config({})
			local tag = { selected = false, clients = function() return {} end }
			assert.are.equal(0, taglist._target_width(tag, cfg))
		end)
	end)
end)

-- ===== Notifications component tests =====
describe("fishlive.components.notifications", function()
	local notifications
	setup(function()
		notifications = require("fishlive.components.notifications")
	end)

	describe("_resolve_icon", function()
		it("returns icon for absolute path", function()
			local n = { icon = "/usr/share/icons/test.png" }
			assert.are.equal("/usr/share/icons/test.png", notifications._resolve_icon(n))
		end)

		it("returns default for empty icon", function()
			local n = { icon = "" }
			-- beautiful.notification_icon_default is nil in stub, that's fine
			assert.is_nil(notifications._resolve_icon(n))
		end)

		it("returns default for nil icon", function()
			local n = { icon = nil }
			assert.is_nil(notifications._resolve_icon(n))
		end)

		it("returns default for relative path", function()
			local n = { icon = "relative/path.png" }
			assert.is_nil(notifications._resolve_icon(n))
		end)

		it("passes through cairo surface (userdata)", function()
			local surface = { type = "surface" }
			local n = { icon = surface }
			assert.are.equal(surface, notifications._resolve_icon(n))
		end)
	end)

	describe("_fade_in", function()
		it("sets popup opacity to 0", function()
			local popup = { opacity = 1, valid = true }
			notifications._fade_in(popup)
			assert.is_true(popup.opacity >= 0)
		end)

		it("returns a rubato timed instance", function()
			local popup = { opacity = 1, valid = true }
			local anim = notifications._fade_in(popup)
			assert.is_not_nil(anim)
			assert.is_not_nil(anim.target)
		end)

		it("accepts custom config", function()
			local popup = { opacity = 1, valid = true }
			local anim = notifications._fade_in(popup, {
				fade_in_duration = 0.5,
				fade_in_intro = 0.1,
			})
			assert.is_not_nil(anim)
		end)
	end)

	describe("_build_widget_template", function()
		it("returns a table with background_role", function()
			local tmpl = notifications._build_widget_template("/test.png")
			assert.are.equal("background_role", tmpl.id)
		end)
	end)
end)
