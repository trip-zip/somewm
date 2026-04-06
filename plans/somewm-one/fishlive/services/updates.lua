---------------------------------------------------------------------------
--- Arch updates service — official + AUR package counts.
--
-- @module fishlive.services.updates
---------------------------------------------------------------------------

local service = require("fishlive.service")
local broker = require("fishlive.broker")

local s = service.new {
	signal   = "data::updates",
	interval = 600,  -- 10 minutes
	command  = [[bash -c '
		official=$(checkupdates 2>/dev/null | wc -l)
		aur=$(paru -Qua 2>/dev/null | wc -l || yay -Qua 2>/dev/null | wc -l || echo 0)
		echo "$official $aur"
	']],
	parser = function(stdout)
		if not stdout or stdout == "" then return nil end
		local official, aur = stdout:match("(%d+)%s+(%d+)")
		if not official then return nil end

		official = tonumber(official) or 0
		aur = tonumber(aur) or 0
		local total = official + aur

		local icon = total > 0 and "󰏔" or "󰏗"

		return {
			official = official,
			aur = aur,
			total = total,
			icon = icon,
		}
	end,
}

broker.register_producer("data::updates", s)
return s
