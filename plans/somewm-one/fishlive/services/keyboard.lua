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

	-- Parse xkb group names: "pc+us+cz(qwerty):2+grp:alt_shift_toggle"
	-- Extract layout codes (us, cz) from the + separated parts
	local names = awesome.xkb_get_group_names()
	if names then
		layout_names = {}
		for part in names:gmatch("[^+]+") do
			-- Skip: pc, evdev, pcXXX, grp:*, compose:*
			if not part:match("^pc") and not part:match("^evdev")
				and not part:match("^grp:") and not part:match("^compose:")
				and not part:match("^ctrl:") and not part:match("^caps:")
				and not part:match("^terminate:") then
				-- Extract base layout name: "cz(qwerty):2" → "cz"
				local layout = part:match("^(%a%a%a?)") -- 2-3 letter code
				if layout then
					layout_names[#layout_names + 1] = layout
				end
			end
		end
		if #layout_names == 0 then
			layout_names = { "us" }
		end
	end

	awesome.connect_signal("xkb::group_changed", update_and_emit)
	update_and_emit()
end

function keyboard:stop()
	if not running then return end
	running = false
	awesome.disconnect_signal("xkb::group_changed", update_and_emit)
end

broker.register_producer("data::keyboard", keyboard)
return keyboard
