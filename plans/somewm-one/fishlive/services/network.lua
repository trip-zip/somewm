---------------------------------------------------------------------------
--- Network service — async read of /proc/net/dev, rate calculation.
--
-- @module fishlive.services.network
---------------------------------------------------------------------------

local service = require("fishlive.service")
local broker = require("fishlive.broker")

local prev_rx, prev_tx, prev_time = 0, 0, 0

-- Fixed-width rate formatting: always 5 chars (e.g. " 512B", " 100K", " 1.5M")
local function format_rate(bytes_per_sec)
	if bytes_per_sec >= 1048576 then
		return string.format("%4.1fM", bytes_per_sec / 1048576)
	elseif bytes_per_sec >= 1024 then
		return string.format("%4.0fK", bytes_per_sec / 1024)
	else
		return string.format("%4dB", bytes_per_sec)
	end
end

local s = service.new {
	signal   = "data::network",
	interval = 2,
	command  = [[bash -c '
		date +%s%N
		cat /proc/net/dev
	']],
	parser = function(stdout)
		if not stdout or stdout == "" then return nil end

		-- First line is timestamp in nanoseconds
		local ts_str, rest = stdout:match("^(%d+)\n(.*)")
		if not ts_str then return nil end
		local now = tonumber(ts_str) / 1000000000  -- convert to seconds

		-- Find primary interface (skip lo, docker, veth, br, virbr)
		local iface, rx, tx
		for line in rest:gmatch("[^\n]+") do
			local name = line:match("^%s*(%S+):")
			if name and name ~= "lo"
				and not name:match("^docker")
				and not name:match("^veth")
				and not name:match("^br%-")
				and not name:match("^virbr") then
				local fields = {}
				for num in line:match(":(.+)"):gmatch("%d+") do
					fields[#fields + 1] = tonumber(num)
				end
				-- fields[1]=rx_bytes, fields[9]=tx_bytes
				if fields[1] and fields[1] > 0 and fields[9] then
					iface = name
					rx = fields[1]
					tx = fields[9]
					break
				end
			end
		end

		if not iface then return nil end

		local dt = now - prev_time
		local rx_rate, tx_rate = 0, 0
		if dt > 0 and prev_time > 0 then
			rx_rate = (rx - prev_rx) / dt
			tx_rate = (tx - prev_tx) / dt
			if rx_rate < 0 then rx_rate = 0 end
			if tx_rate < 0 then tx_rate = 0 end
		end

		prev_rx = rx
		prev_tx = tx
		prev_time = now

		return {
			interface = iface,
			rx_rate = rx_rate,
			tx_rate = tx_rate,
			rx_formatted = format_rate(rx_rate),
			tx_formatted = format_rate(tx_rate),
			icon_down = "󰁅",
			icon_up = "󰁝",
		}
	end,
}

broker.register_producer("data::network", s)
return s
