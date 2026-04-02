---------------------------------------------------------------------------
--- Service base class — data producer with timer lifecycle.
--
-- Services poll data (from /proc files or shell commands) on a timer and
-- emit results through the broker. The broker manages start/stop lifecycle.
--
-- Two modes:
--   poll_fn:  Synchronous function returning data table (for /proc reads)
--   command:  Shell command string + parser function (for async spawns)
--
-- @module fishlive.service
-- @author Antonin Fischer (raven2cz) & Claude
-- @copyright 2026 MIT License
---------------------------------------------------------------------------

local service = {}
service.__index = service

--- Create a new service.
--
-- @tparam table opts Configuration:
--   signal    (string)   Signal name for broker.emit_signal
--   interval  (number)   Poll interval in seconds (default 5)
--   poll_fn   (function) Sync data producer: function() -> data_table or nil
--   command   (string)   Shell command for async polling
--   parser    (function) Parse stdout: function(stdout) -> data_table or nil
--   event_cmd (string)   Long-running event command (e.g. "pactl subscribe")
--   event_filter (function) Filter event lines: function(line) -> bool
-- @treturn service New service instance
function service.new(opts)
	assert(opts.signal, "service requires a signal name")
	assert(opts.poll_fn or opts.command or opts.event_cmd,
		"service requires poll_fn, command, or event_cmd")

	local s = setmetatable({
		signal_name  = opts.signal,
		interval     = opts.interval or 5,
		poll_fn      = opts.poll_fn,
		command      = opts.command,
		parser       = opts.parser or function(stdout) return stdout end,
		event_cmd    = opts.event_cmd,
		event_filter = opts.event_filter,
		_timer       = nil,
		_event_pid   = nil,
		_running     = false,
		_generation  = 0,    -- guards against stale async callbacks
		-- Injected dependencies (overridable for testing)
		_deps        = opts.deps or {},
	}, service)

	return s
end

--- Start the service timer/watcher.
-- Called by broker when first consumer connects.
function service:start()
	if self._running then return end
	self._running = true
	self._generation = self._generation + 1

	local broker = self._deps.broker or require("fishlive.broker")
	local gears_timer = self._deps.timer or require("gears.timer")
	local awful_spawn = self._deps.spawn or require("awful.spawn")

	if self.event_cmd then
		-- Event-driven mode (e.g. pactl subscribe)
		self:_start_event_watcher(broker, awful_spawn)
	elseif self.poll_fn then
		-- Sync polling mode (e.g. /proc reads)
		self._timer = gears_timer {
			timeout   = self.interval,
			autostart = true,
			call_now  = true,
			callback  = function()
				if not self._running then return end
				local data = self.poll_fn()
				if data ~= nil then
					broker.emit_signal(self.signal_name, data)
				end
			end,
		}
	elseif self.command then
		-- Async command mode (e.g. nvidia-smi)
		local gen = self._generation
		self._timer = gears_timer {
			timeout   = self.interval,
			autostart = true,
			call_now  = true,
			callback  = function()
				if not self._running or self._generation ~= gen then return end
				awful_spawn.easy_async_with_shell(self.command, function(stdout)
					if not self._running or self._generation ~= gen then return end
					local data = self.parser(stdout)
					if data ~= nil then
						broker.emit_signal(self.signal_name, data)
					end
				end)
			end,
		}
	end
end

--- Stop the service timer/watcher.
-- Called by broker when last consumer disconnects.
function service:stop()
	if not self._running then return end
	self._running = false
	self._generation = self._generation + 1

	if self._timer then
		self._timer:stop()
		self._timer = nil
	end

	if self._event_pid then
		local awful_spawn = self._deps.spawn or require("awful.spawn")
		awful_spawn.easy_async("kill " .. self._event_pid, function() end)
		self._event_pid = nil
	end
end

--- Start event-driven watcher with auto-restart.
function service:_start_event_watcher(broker, awful_spawn)
	local gen = self._generation

	-- Initial state fetch (if command also provided)
	if self.command then
		awful_spawn.easy_async_with_shell(self.command, function(stdout)
			if not self._running or self._generation ~= gen then return end
			local data = self.parser(stdout)
			if data ~= nil then
				broker.emit_signal(self.signal_name, data)
			end
		end)
	end

	-- Long-running event listener
	local function start_listener()
		if not self._running or self._generation ~= gen then return end
		self._event_pid = awful_spawn.with_line_callback(self.event_cmd, {
			stdout = function(line)
				if not self._running or self._generation ~= gen then return end
				local should_update = not self.event_filter or self.event_filter(line)
				if should_update and self.command then
					awful_spawn.easy_async_with_shell(self.command, function(stdout)
						if not self._running or self._generation ~= gen then return end
						local data = self.parser(stdout)
						if data ~= nil then
							broker.emit_signal(self.signal_name, data)
						end
					end)
				end
			end,
			exit = function()
				-- Auto-restart on 5s delay if still running
				if self._running and self._generation == gen then
					local gears_timer = self._deps.timer or require("gears.timer")
					gears_timer.start_new(5, function()
						start_listener()
						return false  -- one-shot
					end)
				end
			end,
		})
	end

	start_listener()
end

return service
