---------------------------------------------------------------------------
--- Volume service — PipeWire via wpctl + pactl subscribe events.
--
-- Event-driven: pactl subscribe detects changes, wpctl reads state.
-- Auto-restarts pactl if it dies (PipeWire restart).
--
-- @module fishlive.services.volume
---------------------------------------------------------------------------

local service = require("fishlive.service")
local broker = require("fishlive.broker")

local function parse_volume(stdout)
	if not stdout or stdout == "" then return nil end
	-- wpctl output: "Volume: 0.75" or "Volume: 0.75 [MUTED]"
	local vol = stdout:match("Volume:%s+(%d+%.?%d*)")
	if not vol then return nil end

	local volume = math.floor(tonumber(vol) * 100 + 0.5)
	local muted = stdout:match("%[MUTED%]") ~= nil

	local icon
	if muted then
		icon = "󰝟"
	elseif volume > 70 then
		icon = "󰕾"
	elseif volume > 30 then
		icon = "󰖀"
	elseif volume > 0 then
		icon = "󰕿"
	else
		icon = "󰝟"
	end

	return {
		volume = volume,
		muted = muted,
		icon = icon,
	}
end

local s = service.new {
	signal       = "data::volume",
	command      = "wpctl get-volume @DEFAULT_AUDIO_SINK@",
	parser       = parse_volume,
	event_cmd    = "pactl subscribe",
	event_filter = function(line)
		-- Only react to sink changes
		return line:match("sink") ~= nil or line:match("server") ~= nil
	end,
}

broker.register_producer("data::volume", s)
return s
