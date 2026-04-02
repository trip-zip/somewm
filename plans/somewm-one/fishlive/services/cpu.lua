---------------------------------------------------------------------------
--- CPU usage + temperature service — async reads via shell.
--
-- @module fishlive.services.cpu
---------------------------------------------------------------------------

local service = require("fishlive.service")
local broker = require("fishlive.broker")

local prev_idle, prev_total = 0, 0

local s = service.new {
	signal   = "data::cpu",
	interval = 2,
	command  = [[bash -c '
		head -1 /proc/stat
		echo "---"
		for h in /sys/class/hwmon/hwmon*; do
			name=$(cat "$h/name" 2>/dev/null)
			case "$name" in k10temp|coretemp|cpu_thermal)
				cat "$h/temp1_input" 2>/dev/null
				break
				;;
			esac
		done
		if [ -z "$name" ]; then
			for z in /sys/class/thermal/thermal_zone*; do
				t=$(cat "$z/type" 2>/dev/null)
				case "$t" in x86_pkg*|coretemp|k10temp|cpu*)
					cat "$z/temp" 2>/dev/null
					break
					;;
				esac
			done
		fi
	']],
	parser = function(stdout)
		if not stdout or stdout == "" then return nil end

		local stat_line, rest = stdout:match("^(.-)\n---\n(.*)")
		if not stat_line then return nil end

		local user, nice, system, idle, iowait, irq, softirq, steal =
			stat_line:match("cpu%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)")
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

		local temp = nil
		local raw_temp = rest and rest:match("(%d+)")
		if raw_temp then
			temp = math.floor(tonumber(raw_temp) / 1000 + 0.5)
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
