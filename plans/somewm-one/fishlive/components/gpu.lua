local wibox = require("wibox")
local beautiful = require("beautiful")
local broker = require("fishlive.broker")
local wh = require("fishlive.widget_helper")

local M = {}

function M.create(screen, config)
	local color = beautiful.widget_gpu_color or "#98c379"
	local widget, update = wh.create_icon_text(color)

	broker.connect_signal("data::gpu", function(data)
		update(data.icon, string.format("%3d%% %2d°C", data.usage, data.temp))
	end)

	return widget
end

return M
