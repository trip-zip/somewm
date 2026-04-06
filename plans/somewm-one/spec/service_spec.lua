---------------------------------------------------------------------------
--- Tests for fishlive.service
---------------------------------------------------------------------------

package.path = "./plans/somewm-one/?.lua;" .. package.path

-- Mock gears.timer
local mock_timers = {}
package.preload["gears.timer"] = function()
	local timer_mt = {}
	timer_mt.__index = timer_mt

	function timer_mt:stop()
		self.running = false
	end

	local function create_timer(opts)
		local t = setmetatable({
			timeout = opts.timeout,
			running = opts.autostart or false,
			callback = opts.callback,
		}, timer_mt)
		table.insert(mock_timers, t)
		if opts.call_now and opts.callback then
			opts.callback()
		end
		return t
	end

	-- gears.timer also used as constructor
	return setmetatable({
		start_new = function(timeout, fn)
			fn()  -- immediate for testing
			return {}
		end,
	}, { __call = function(_, opts) return create_timer(opts) end })
end

-- Mock awful.spawn
local spawn_calls = {}
package.preload["awful.spawn"] = function()
	return {
		easy_async_with_shell = function(cmd, cb)
			table.insert(spawn_calls, { cmd = cmd, type = "async" })
			-- Simulate immediate response for testing
			cb("mock stdout")
		end,
		easy_async = function(cmd, cb)
			cb("")
		end,
		with_line_callback = function(cmd, opts)
			table.insert(spawn_calls, { cmd = cmd, type = "event" })
			return 12345  -- mock PID
		end,
	}
end

describe("service", function()
	local service, broker

	before_each(function()
		mock_timers = {}
		spawn_calls = {}
		package.loaded["fishlive.service"] = nil
		package.loaded["fishlive.broker"] = nil
		service = require("fishlive.service")
		broker = require("fishlive.broker")
	end)

	after_each(function()
		broker._reset()
	end)

	describe("new", function()
		it("creates a service with poll_fn", function()
			local s = service.new {
				signal = "data::test",
				interval = 2,
				poll_fn = function() return { value = 42 } end,
			}
			assert.are.equal("data::test", s.signal_name)
			assert.are.equal(2, s.interval)
			assert.is_false(s._running)
		end)

		it("creates a service with command", function()
			local s = service.new {
				signal = "data::cmd",
				command = "echo hello",
				parser = function(stdout) return { text = stdout } end,
			}
			assert.are.equal("data::cmd", s.signal_name)
		end)

		it("rejects service without signal", function()
			assert.has_error(function()
				service.new { poll_fn = function() end }
			end)
		end)

		it("rejects service without data source", function()
			assert.has_error(function()
				service.new { signal = "data::empty" }
			end)
		end)
	end)

	describe("poll_fn mode", function()
		it("emits data through broker on start", function()
			local s = service.new {
				signal = "data::poll",
				interval = 2,
				poll_fn = function() return { value = 100 } end,
				deps = { broker = broker },
			}

			local received = nil
			broker.connect_signal("data::poll", function(d) received = d end)

			s:start()
			assert.is_true(s._running)
			assert.are.equal(100, received.value)
		end)

		it("skips nil data from poll_fn", function()
			local calls = 0
			local s = service.new {
				signal = "data::nilpoll",
				interval = 1,
				poll_fn = function() return nil end,
				deps = { broker = broker },
			}

			broker.connect_signal("data::nilpoll", function()
				calls = calls + 1
			end)

			s:start()
			assert.are.equal(0, calls)
		end)

		it("stops timer on stop", function()
			local s = service.new {
				signal = "data::stoppoll",
				interval = 1,
				poll_fn = function() return { x = 1 } end,
				deps = { broker = broker },
			}
			s:start()
			assert.is_true(s._running)

			s:stop()
			assert.is_false(s._running)
			assert.is_nil(s._timer)
		end)

		it("ignores double start", function()
			local count = 0
			local s = service.new {
				signal = "data::dblstart",
				interval = 1,
				poll_fn = function() count = count + 1; return { n = count } end,
				deps = { broker = broker },
			}
			s:start()
			s:start()  -- should be no-op
			assert.are.equal(1, count)  -- call_now fires once
		end)
	end)

	describe("command mode", function()
		it("spawns command and parses output", function()
			local s = service.new {
				signal = "data::cmd",
				command = "echo test",
				parser = function(stdout) return { text = stdout:gsub("%s+$", "") } end,
				deps = { broker = broker },
			}

			local received = nil
			broker.connect_signal("data::cmd", function(d) received = d end)

			s:start()
			assert.are.equal("mock stdout", received.text)
		end)
	end)

	describe("generation guard", function()
		it("increments generation on start/stop", function()
			local s = service.new {
				signal = "data::gen",
				poll_fn = function() return {} end,
				deps = { broker = broker },
			}
			assert.are.equal(0, s._generation)
			s:start()
			assert.are.equal(1, s._generation)
			s:stop()
			assert.are.equal(2, s._generation)
		end)
	end)

	describe("broker integration", function()
		it("auto-starts via broker lazy lifecycle", function()
			local started = false
			local s = service.new {
				signal = "data::lazy",
				poll_fn = function() return { v = 1 } end,
				deps = { broker = broker },
			}
			-- Wrap start to track
			local orig_start = s.start
			s.start = function(self)
				started = true
				return orig_start(self)
			end

			broker.register_producer("data::lazy", s)
			assert.is_false(started)

			broker.connect_signal("data::lazy", function() end)
			assert.is_true(started)
		end)
	end)
end)
