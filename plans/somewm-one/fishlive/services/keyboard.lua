---------------------------------------------------------------------------
--- Keyboard layout service — xkb event-driven, no polling.
--
-- Uses somewm's native xkb::group_changed signal.
--
-- @module fishlive.services.keyboard
---------------------------------------------------------------------------

local broker = require("fishlive.broker")

local keyboard = {}
local running = false

-- Layout names (populated from xkb config)
local layout_names = {}

local function get_current_layout()
	local group = awesome.xkb_get_layout_group()
	return layout_names[group + 1] or tostring(group)
end

local function update_and_emit()
	local current = get_current_layout()
	broker.emit_signal("data::keyboard", {
		layout = current,
		layouts = layout_names,
		icon = "󰌌",
	})
end

function keyboard:start()
	if running then return end
	running = true

	-- Detect available layouts from xkb rules
	-- awesome.xkb_get_group_names() returns "rules+model+layout1+layout2+..."
	local names = awesome.xkb_get_group_names()
	if names then
		layout_names = {}
		-- Format: "evdev+pc105+us+cz+..." — layouts start at 4th field
		local parts = {}
		for part in names:gmatch("[^+]+") do
			parts[#parts + 1] = part
		end
		-- Skip rules, model, variant prefixes — layouts are after model
		-- Heuristic: take 2-letter codes
		for i = 3, #parts do
			if #parts[i] <= 3 then
				layout_names[#layout_names + 1] = parts[i]
			end
		end
		if #layout_names == 0 then
			layout_names = { "us" }
		end
	end

	awesome.connect_signal("xkb::group_changed", update_and_emit)
	update_and_emit()  -- Initial state
end

function keyboard:stop()
	if not running then return end
	running = false
	awesome.disconnect_signal("xkb::group_changed", update_and_emit)
end

broker.register_producer("data::keyboard", keyboard)
return keyboard
