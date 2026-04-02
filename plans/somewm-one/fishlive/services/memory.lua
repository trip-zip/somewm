---------------------------------------------------------------------------
--- Memory usage service — reads /proc/meminfo.
--
-- @module fishlive.services.memory
---------------------------------------------------------------------------

local service = require("fishlive.service")
local broker = require("fishlive.broker")

local s = service.new {
	signal   = "data::memory",
	interval = 3,
	poll_fn  = function()
		local f = io.open("/proc/meminfo")
		if not f then return nil end
		local content = f:read("*a")
		f:close()

		local mem_total = tonumber(content:match("MemTotal:%s+(%d+)"))
		local mem_free = tonumber(content:match("MemFree:%s+(%d+)"))
		local mem_avail = tonumber(content:match("MemAvailable:%s+(%d+)"))
		local swap_total = tonumber(content:match("SwapTotal:%s+(%d+)"))
		local swap_free = tonumber(content:match("SwapFree:%s+(%d+)"))

		if not mem_total or not mem_avail then return nil end

		local used = mem_total - mem_avail
		local percent = math.floor(used / mem_total * 100 + 0.5)
		local swap_used = (swap_total or 0) - (swap_free or 0)

		-- Convert kB to MB for display
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
