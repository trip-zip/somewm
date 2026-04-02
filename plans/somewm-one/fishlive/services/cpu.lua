---------------------------------------------------------------------------
--- CPU usage service — reads /proc/stat, computes usage percentage.
--
-- @module fishlive.services.cpu
---------------------------------------------------------------------------

local service = require("fishlive.service")
local broker = require("fishlive.broker")

local prev_idle, prev_total = 0, 0

local s = service.new {
	signal   = "data::cpu",
	interval = 2,
	poll_fn  = function()
		local f = io.open("/proc/stat")
		if not f then return nil end
		local line = f:read("*l")
		f:close()

		-- cpu  user nice system idle iowait irq softirq steal
		local user, nice, system, idle, iowait, irq, softirq, steal =
			line:match("cpu%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)")

		if not user then return nil end

		user, nice, system, idle = tonumber(user), tonumber(nice), tonumber(system), tonumber(idle)
		iowait, irq, softirq, steal = tonumber(iowait), tonumber(irq), tonumber(softirq), tonumber(steal)

		local total = user + nice + system + idle + iowait + irq + softirq + steal
		local idle_total = idle + iowait

		local diff_idle = idle_total - prev_idle
		local diff_total = total - prev_total

		prev_idle = idle_total
		prev_total = total

		if diff_total == 0 then return nil end

		local usage = math.floor((1 - diff_idle / diff_total) * 100 + 0.5)

		-- CPU temperature from thermal zone
		local temp = nil
		for i = 0, 10 do
			local tf = io.open("/sys/class/thermal/thermal_zone" .. i .. "/type")
			if tf then
				local ztype = tf:read("*l")
				tf:close()
				if ztype and (ztype:match("x86_pkg") or ztype:match("coretemp")
						or ztype:match("k10temp") or ztype:match("cpu")) then
					local vf = io.open("/sys/class/thermal/thermal_zone" .. i .. "/temp")
					if vf then
						local raw = tonumber(vf:read("*l"))
						vf:close()
						if raw then temp = math.floor(raw / 1000 + 0.5) end
					end
					break
				end
			end
		end

		return {
			usage = usage,
			temp = temp,
			icon = "󰻠",
		}
	end,
}

broker.register_producer("data::cpu", s)
return s
