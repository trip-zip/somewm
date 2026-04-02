---------------------------------------------------------------------------
--- Tests for fishlive.broker
---------------------------------------------------------------------------

-- Minimal stubs so broker.lua can be required without awesome runtime
package.path = "./plans/somewm-one/?.lua;" .. package.path

describe("broker", function()
	local broker

	before_each(function()
		-- Fresh broker each test (bypass require cache)
		package.loaded["fishlive.broker"] = nil
		broker = require("fishlive.broker")
	end)

	after_each(function()
		broker._reset()
	end)

	describe("connect_signal / emit_signal", function()
		it("delivers data to connected consumer", function()
			local received = nil
			broker.connect_signal("test::signal", function(data)
				received = data
			end)
			broker.emit_signal("test::signal", { value = 42 })
			assert.are.equal(42, received.value)
		end)

		it("delivers to multiple consumers", function()
			local a, b = nil, nil
			broker.connect_signal("test::multi", function(d) a = d.value end)
			broker.connect_signal("test::multi", function(d) b = d.value end)
			broker.emit_signal("test::multi", { value = 99 })
			assert.are.equal(99, a)
			assert.are.equal(99, b)
		end)

		it("ignores nil data (no emit, no cache)", function()
			local called = false
			broker.connect_signal("test::nil", function() called = true end)
			broker.emit_signal("test::nil", nil)
			assert.is_false(called)
			assert.is_nil(broker.get_value("test::nil"))
		end)

		it("delivers cached value to late-joining consumer", function()
			broker.emit_signal("test::cache", { value = 7 })
			local received = nil
			broker.connect_signal("test::cache", function(d) received = d.value end)
			assert.are.equal(7, received)
		end)
	end)

	describe("disconnect_signal", function()
		it("stops delivery after disconnect", function()
			local count = 0
			local fn = function() count = count + 1 end
			broker.connect_signal("test::disc", fn)
			broker.emit_signal("test::disc", { x = 1 })
			assert.are.equal(1, count)

			broker.disconnect_signal("test::disc", fn)
			broker.emit_signal("test::disc", { x = 2 })
			assert.are.equal(1, count) -- not called again
		end)

		it("returns disconnect function from connect", function()
			local count = 0
			local disconnect = broker.connect_signal("test::retfn", function()
				count = count + 1
			end)
			broker.emit_signal("test::retfn", { x = 1 })
			assert.are.equal(1, count)

			disconnect()
			broker.emit_signal("test::retfn", { x = 2 })
			assert.are.equal(1, count)
		end)
	end)

	describe("error isolation", function()
		it("one consumer crash doesn't affect others", function()
			local received = nil
			broker.connect_signal("test::err", function()
				error("boom!")
			end)
			broker.connect_signal("test::err", function(d)
				received = d.value
			end)
			-- Should not throw
			broker.emit_signal("test::err", { value = 55 })
			assert.are.equal(55, received)
		end)
	end)

	describe("get_value", function()
		it("returns nil for unknown signal", function()
			assert.is_nil(broker.get_value("nonexistent"))
		end)

		it("returns last emitted value", function()
			broker.emit_signal("test::val", { a = 1 })
			broker.emit_signal("test::val", { a = 2 })
			assert.are.equal(2, broker.get_value("test::val").a)
		end)
	end)

	describe("lazy producer lifecycle", function()
		it("starts producer on first consumer connect", function()
			local started = false
			local mock_producer = {
				start = function() started = true end,
				stop = function() end,
			}
			broker.register_producer("test::lazy", mock_producer)
			assert.is_false(started)

			broker.connect_signal("test::lazy", function() end)
			assert.is_true(started)
		end)

		it("stops producer when last consumer disconnects", function()
			local stopped = false
			local mock_producer = {
				start = function() end,
				stop = function() stopped = true end,
			}
			broker.register_producer("test::stop", mock_producer)

			local fn1 = function() end
			local fn2 = function() end
			broker.connect_signal("test::stop", fn1)
			broker.connect_signal("test::stop", fn2)

			broker.disconnect_signal("test::stop", fn1)
			assert.is_false(stopped) -- still one consumer

			broker.disconnect_signal("test::stop", fn2)
			assert.is_true(stopped) -- last consumer gone
		end)

		it("retroactive start when consumers already waiting", function()
			local started = false
			broker.connect_signal("test::retro", function() end)

			broker.register_producer("test::retro", {
				start = function() started = true end,
				stop = function() end,
			})
			assert.is_true(started)
		end)
	end)

	describe("_reset", function()
		it("clears all state", function()
			broker.emit_signal("test::reset", { x = 1 })
			broker.connect_signal("test::reset", function() end)
			broker._reset()

			assert.is_nil(broker.get_value("test::reset"))
		end)
	end)
end)
