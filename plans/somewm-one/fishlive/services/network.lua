---------------------------------------------------------------------------
--- Network service — upload/download rates from /proc/net/dev.
--
-- Reads byte counters and computes rate by delta with previous sample.
--
-- @module fishlive.services.network
---------------------------------------------------------------------------

local service = require("fishlive.service")
local broker = require("fishlive.broker")

-- State for delta computation
local last_rx, last_tx, last_ts = 0, 0, 0

-- Find the primary network interface (skip lo, docker, veth, br, virbr)
local function find_interface()
	local f = io.open("/proc/net/dev")
	if not f then return nil end
	local content = f:read("*a")
	f:close()

	for line in content:gmatch("[^\n]+") do
		local iface = line:match("^%s*(%S+):")
		if iface and iface ~= "lo"
			and not iface:match("^docker")
			and not iface:match("^veth")
			and not iface:match("^br%-")
			and not iface:match("^virbr") then
			-- Check if it has traffic (rx_bytes > 0)
			local rx = tonumber(line:match(":%s*(%d+)"))
			if rx and rx > 0 then
				return iface
			end
		end
	end
	return nil
end

local cached_iface = nil

local function format_rate(bytes_per_sec)
	if bytes_per_sec >= 1048576 then
		return string.format("%.1fM", bytes_per_sec / 1048576)
	elseif bytes_per_sec >= 1024 then
		return string.format("%.0fK", bytes_per_sec / 1024)
	else
		return string.format("%dB", bytes_per_sec)
	end
end

local s = service.new {
	signal   = "data::network",
	interval = 2,
	poll_fn  = function()
		if not cached_iface then
			cached_iface = find_interface()
		end
		if not cached_iface then return nil end

		local f = io.open("/proc/net/dev")
		if not f then return nil end
		local content = f:read("*a")
		f:close()

		for line in content:gmatch("[^\n]+") do
			if line:match("^%s*" .. cached_iface .. ":") then
				-- Fields: iface: rx_bytes rx_packets ... tx_bytes tx_packets ...
				local fields = {}
				for num in line:match(":(.+)"):gmatch("%d+") do
					fields[#fields + 1] = tonumber(num)
				end
				-- fields[1] = rx_bytes, fields[9] = tx_bytes
				local rx, tx = fields[1], fields[9]
				if not rx or not tx then return nil end

				local now = os.clock()
				local dt = now - last_ts

				local rx_rate, tx_rate = 0, 0
				if dt > 0 and last_ts > 0 then
					rx_rate = (rx - last_rx) / dt
					tx_rate = (tx - last_tx) / dt
				end

				last_rx = rx
				last_tx = tx
				last_ts = now

				return {
					interface = cached_iface,
					rx_rate = rx_rate,
					tx_rate = tx_rate,
					rx_formatted = format_rate(rx_rate),
					tx_formatted = format_rate(tx_rate),
					icon_down = "󰁅",
					icon_up = "󰁝",
				}
			end
		end

		-- Interface disappeared (cable unplugged?) — retry detection
		cached_iface = nil
		return nil
	end,
}

broker.register_producer("data::network", s)
return s
