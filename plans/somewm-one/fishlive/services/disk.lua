---------------------------------------------------------------------------
--- Disk usage service — btrfs-aware with df fallback.
--
-- @module fishlive.services.disk
---------------------------------------------------------------------------

local service = require("fishlive.service")
local broker = require("fishlive.broker")

-- Configurable mount points (override via service config)
local monitored_mounts = { "/" }

local s = service.new {
	signal   = "data::disk",
	interval = 60,
	command  = [[bash -c '
		for mount in ]] .. table.concat(monitored_mounts, " ") .. [[; do
			fstype=$(findmnt -n -o FSTYPE "$mount" 2>/dev/null)
			if [ "$fstype" = "btrfs" ]; then
				# btrfs: get real usage accounting for compression/dedup
				raw=$(btrfs filesystem usage -b "$mount" 2>/dev/null)
				used=$(echo "$raw" | grep "Used:" | head -1 | grep -oP "\d+" | head -1)
				size=$(echo "$raw" | grep "Device size:" | grep -oP "\d+" | head -1)
				if [ -n "$used" ] && [ -n "$size" ] && [ "$size" -gt 0 ]; then
					perc=$((used * 100 / size))
					echo "BTRFS:$mount:$used:$size:$perc"
				fi
			else
				# Standard df fallback
				df -B1 "$mount" 2>/dev/null | tail -1 | awk "{print \"DF:$mount:\" \$3 \":\" \$2 \":\" int(\$3/\$2*100)}"
			fi
		done
	']],
	parser = function(stdout)
		if not stdout or stdout == "" then return nil end

		local mounts = {}
		for line in stdout:gmatch("[^\n]+") do
			local fstype, mount, used, total, percent =
				line:match("(%u+):(%S+):(%d+):(%d+):(%d+)")
			if mount then
				local gb_used = tonumber(used) / 1073741824
				local gb_total = tonumber(total) / 1073741824
				mounts[mount] = {
					fstype = fstype:lower(),
					used = string.format("%.0f", gb_used),
					total = string.format("%.0f", gb_total),
					percent = tonumber(percent),
				}
			end
		end

		if not next(mounts) then return nil end

		-- Primary mount for quick display
		local primary = mounts["/"] or mounts[next(mounts)]

		return {
			mounts = mounts,
			percent = primary and primary.percent or 0,
			used = primary and primary.used or "?",
			total = primary and primary.total or "?",
			icon = "󰋊",
		}
	end,
}

broker.register_producer("data::disk", s)
return s
