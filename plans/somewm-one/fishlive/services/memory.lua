---------------------------------------------------------------------------
--- Memory usage service — async read of /proc/meminfo.
--
-- @module fishlive.services.memory
---------------------------------------------------------------------------

local service = require("fishlive.service")
local broker = require("fishlive.broker")

local s = service.new {
	signal   = "data::memory",
	interval = 3,
	command  = "cat /proc/meminfo",
	parser   = function(stdout)
		if not stdout or stdout == "" then return nil end

		local mem_total = tonumber(stdout:match("MemTotal:%s+(%d+)"))
		local mem_free = tonumber(stdout:match("MemFree:%s+(%d+)"))
		local mem_avail = tonumber(stdout:match("MemAvailable:%s+(%d+)"))
		local swap_total = tonumber(stdout:match("SwapTotal:%s+(%d+)"))
		local swap_free = tonumber(stdout:match("SwapFree:%s+(%d+)"))

		if not mem_total or not mem_avail then return nil end

		local used = mem_total - mem_avail
		local percent = math.floor(used / mem_total * 100 + 0.5)
		local swap_used = (swap_total or 0) - (swap_free or 0)

		return {
			used = math.floor(used / 1024),
			total = math.floor(mem_total / 1024),
			free = math.floor((mem_free or 0) / 1024),
			percent = percent,
			swap_used = math.floor(swap_used / 1024),
			swap_total = math.floor((swap_total or 0) / 1024),
			icon = "󰍛",
		}
	end,
}

broker.register_producer("data::memory", s)
return s
