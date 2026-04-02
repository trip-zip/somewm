---------------------------------------------------------------------------
--- GPU service — NVIDIA GPU usage and temperature via nvidia-smi.
--
-- Falls back gracefully if nvidia-smi is not available.
--
-- @module fishlive.services.gpu
---------------------------------------------------------------------------

local service = require("fishlive.service")
local broker = require("fishlive.broker")

local s = service.new {
	signal   = "data::gpu",
	interval = 3,
	command  = "nvidia-smi --query-gpu=utilization.gpu,temperature.gpu,name --format=csv,noheader,nounits 2>/dev/null",
	parser   = function(stdout)
		if not stdout or stdout == "" then return nil end

		local usage, temp, name = stdout:match("(%d+),%s*(%d+),%s*(.+)")
		if not usage then return nil end

		return {
			usage = tonumber(usage),
			temp = tonumber(temp),
			name = name:gsub("%s+$", ""),
			icon = "󰢮",
		}
	end,
}

broker.register_producer("data::gpu", s)
return s
