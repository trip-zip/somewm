---------------------------------------------------------------------------
--- Taglist component — rubato-animated underline indicator.
--
-- Standard taglist with bg/fg from theme (background_role) plus a small
-- animated underline bar at the bottom of each tag.
--
-- @module fishlive.components.taglist
-- @author Antonin Fischer (raven2cz) & Claude
-- @copyright 2026 MIT License
---------------------------------------------------------------------------

local awful     = require("awful")
local wibox     = require("wibox")
local gears     = require("gears")
local beautiful = require("beautiful")
local rubato    = require("fishlive.rubato")
local dpi       = beautiful.xresources.apply_dpi

local M = {}

local function resolve_config(config)
	return {
		underline_height   = config.underline_height   or dpi(3),
		underline_selected = config.underline_selected  or dpi(20),
		underline_occupied = config.underline_occupied  or 0,
		underline_empty    = config.underline_empty     or 0,
		underline_color    = config.underline_color     or beautiful.taglist_bg_focus or "#e2b55a",
		anim_duration      = config.anim_duration      or 0.2,
		anim_intro         = config.anim_intro         or 0.1,
	}
end

local function target_width(tag, cfg)
	if tag.selected then
		return cfg.underline_selected
	elseif #tag:clients() > 0 then
		return cfg.underline_occupied
	else
		return cfg.underline_empty
	end
end

--- Apply animation update for a tag widget.
local function update_tag_widget(self, tag, cfg)
	if not self._rubato_width then return end
	self._rubato_width.target = target_width(tag, cfg)
end

function M.create(screen, config)
	local cfg = resolve_config(config or {})

	return awful.widget.taglist {
		screen  = screen,
		filter  = awful.widget.taglist.filter.all,
		buttons = {
			awful.button({ }, 1, function(t) t:view_only() end),
			awful.button({ "Mod4" }, 1, function(t)
				if client.focus then client.focus:move_to_tag(t) end
			end),
			awful.button({ }, 3, awful.tag.viewtoggle),
			awful.button({ "Mod4" }, 3, function(t)
				if client.focus then client.focus:toggle_tag(t) end
			end),
			awful.button({ }, 4, function(t) awful.tag.viewprev(t.screen) end),
			awful.button({ }, 5, function(t) awful.tag.viewnext(t.screen) end),
		},
		widget_template = {
			{
				{
					-- Text + padding
					{
						id     = "text_role",
						widget = wibox.widget.textbox,
					},
					left   = dpi(6),
					right  = dpi(6),
					widget = wibox.container.margin,
				},
				-- Underline bar (centered, animated width)
				{
					id            = "underline_bar",
					bg            = cfg.underline_color,
					forced_height = 0,
					forced_width  = 0,
					shape         = gears.shape.rounded_bar,
					widget        = wibox.container.background,
				},
				layout  = wibox.layout.fixed.vertical,
			},
			id     = "background_role",
			widget = wibox.container.background,
			create_callback = function(self, tag)
				local initial = target_width(tag, cfg)
				local bar = self:get_children_by_id("underline_bar")[1]
				if bar then
					bar.forced_width = initial
					bar.forced_height = initial > 0 and cfg.underline_height or 0
				end

				self._rubato_width = rubato.timed {
					pos            = initial,
					rate           = 60,
					duration       = cfg.anim_duration,
					intro          = cfg.anim_intro,
					easing         = rubato.easing.quadratic,
					clamp_position = true,
					subscribed     = function(pos)
						local b = self:get_children_by_id("underline_bar")[1]
						if b then
							local w = math.max(0, math.floor(pos))
							b.forced_width = w
							b.forced_height = w > 0 and cfg.underline_height or 0
						end
					end,
				}

				-- Direct signal connection ensures animation fires
				-- regardless of how the tag switch was triggered
				tag:connect_signal("property::selected", function()
					update_tag_widget(self, tag, cfg)
				end)
				tag:connect_signal("tagged", function()
					update_tag_widget(self, tag, cfg)
				end)
				tag:connect_signal("untagged", function()
					update_tag_widget(self, tag, cfg)
				end)
			end,
			update_callback = function(self, tag)
				update_tag_widget(self, tag, cfg)
			end,
		},
	}
end

M._resolve_config = resolve_config
M._target_width = target_width

return M
