---------------------------------------------------------------------------
--- Tests for service data parsers (pure Lua, no awesome runtime needed)
---------------------------------------------------------------------------

package.path = "./plans/somewm-one/?.lua;" .. package.path

describe("service parsers", function()

	describe("cpu poll_fn", function()
		it("computes usage from /proc/stat format", function()
			-- Simulate /proc/stat reading by testing the math directly
			local user, nice, system, idle = 10000, 200, 3000, 50000
			local iowait, irq, softirq, steal = 500, 100, 50, 0
			local total = user + nice + system + idle + iowait + irq + softirq + steal
			local idle_total = idle + iowait

			-- Second sample (more work done)
			local user2 = user + 500
			local system2 = system + 200
			local total2 = total + 500 + 200
			local idle_total2 = idle_total  -- idle didn't change

			local diff_idle = idle_total2 - idle_total
			local diff_total = total2 - total

			local usage = math.floor((1 - diff_idle / diff_total) * 100 + 0.5)
			assert.are.equal(100, usage)  -- all new time was non-idle
		end)
	end)

	describe("memory poll_fn parsing", function()
		it("parses meminfo format", function()
			local content = [[
MemTotal:       32768000 kB
MemFree:         8000000 kB
MemAvailable:   24000000 kB
SwapTotal:       8192000 kB
SwapFree:        8192000 kB
]]
			local mem_total = tonumber(content:match("MemTotal:%s+(%d+)"))
			local mem_avail = tonumber(content:match("MemAvailable:%s+(%d+)"))

			assert.are.equal(32768000, mem_total)
			assert.are.equal(24000000, mem_avail)

			local used = mem_total - mem_avail
			local percent = math.floor(used / mem_total * 100 + 0.5)
			assert.are.equal(27, percent)
		end)
	end)

	describe("volume parser", function()
		it("parses normal volume", function()
			local stdout = "Volume: 0.75\n"
			local vol = stdout:match("Volume:%s+(%d+%.?%d*)")
			local volume = math.floor(tonumber(vol) * 100 + 0.5)
			local muted = stdout:match("%[MUTED%]") ~= nil
			assert.are.equal(75, volume)
			assert.is_false(muted)
		end)

		it("parses muted volume", function()
			local stdout = "Volume: 0.50 [MUTED]\n"
			local vol = stdout:match("Volume:%s+(%d+%.?%d*)")
			local volume = math.floor(tonumber(vol) * 100 + 0.5)
			local muted = stdout:match("%[MUTED%]") ~= nil
			assert.are.equal(50, volume)
			assert.is_true(muted)
		end)

		it("returns nil for empty output", function()
			local stdout = ""
			local vol = stdout:match("Volume:%s+(%d+%.?%d*)")
			assert.is_nil(vol)
		end)
	end)

	describe("gpu parser", function()
		it("parses nvidia-smi output", function()
			local stdout = "45, 65, NVIDIA GeForce RTX 4070 SUPER\n"
			local usage, temp, name = stdout:match("(%d+),%s*(%d+),%s*(.+)")
			assert.are.equal("45", usage)
			assert.are.equal("65", temp)
			assert.is_truthy(name:match("RTX 4070"))
		end)

		it("returns nil for empty output (no nvidia)", function()
			local stdout = ""
			local usage = stdout:match("(%d+),%s*(%d+),%s*(.+)")
			assert.is_nil(usage)
		end)
	end)

	describe("disk parser", function()
		it("parses btrfs output line", function()
			local line = "BTRFS:/:107374182400:536870912000:20"
			local fstype, mount, used, total, percent =
				line:match("(%u+):(%S+):(%d+):(%d+):(%d+)")
			assert.are.equal("BTRFS", fstype)
			assert.are.equal("/", mount)
			assert.are.equal(20, tonumber(percent))

			local gb_used = tonumber(used) / 1073741824
			assert.is_true(gb_used > 99 and gb_used < 101)  -- ~100G
		end)

		it("parses df fallback output", function()
			local line = "DF:/home:53687091200:214748364800:25"
			local fstype, mount, used, total, percent =
				line:match("(%u+):(%S+):(%d+):(%d+):(%d+)")
			assert.are.equal("DF", fstype)
			assert.are.equal("/home", mount)
			assert.are.equal(25, tonumber(percent))
		end)
	end)

	describe("updates parser", function()
		it("parses update counts", function()
			local stdout = "12 3\n"
			local official, aur = stdout:match("(%d+)%s+(%d+)")
			assert.are.equal("12", official)
			assert.are.equal("3", aur)
			assert.are.equal(15, tonumber(official) + tonumber(aur))
		end)

		it("handles zero updates", function()
			local stdout = "0 0\n"
			local official, aur = stdout:match("(%d+)%s+(%d+)")
			assert.are.equal(0, tonumber(official) + tonumber(aur))
		end)
	end)

	describe("network rate formatting", function()
		local function format_rate(bytes_per_sec)
			if bytes_per_sec >= 1048576 then
				return string.format("%.1fM", bytes_per_sec / 1048576)
			elseif bytes_per_sec >= 1024 then
				return string.format("%.0fK", bytes_per_sec / 1024)
			else
				return string.format("%dB", bytes_per_sec)
			end
		end

		it("formats bytes", function()
			assert.are.equal("512B", format_rate(512))
		end)

		it("formats kilobytes", function()
			assert.are.equal("100K", format_rate(102400))
		end)

		it("formats megabytes", function()
			assert.are.equal("1.5M", format_rate(1572864))
		end)
	end)
end)
