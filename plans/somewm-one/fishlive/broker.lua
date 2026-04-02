---------------------------------------------------------------------------
--- Signal broker — pub/sub with lazy producer lifecycle and error isolation.
--
-- Data producers (services) register with signal names. View components
-- subscribe to signals. The broker auto-starts a producer when its first
-- consumer connects, and stops it when the last disconnects.
--
-- @module fishlive.broker
-- @author Antonin Fischer (raven2cz) & Claude
-- @copyright 2026 MIT License
---------------------------------------------------------------------------

local broker = {
	_values   = {},   -- signal_name -> last emitted value
	_signals  = {},   -- signal_name -> { consumers = {fn=true}, producer = service }
}

--- Get or create signal entry.
local function get_signal(name)
	if not broker._signals[name] then
		broker._signals[name] = {
			consumers = {},
			producer = nil,
		}
	end
	return broker._signals[name]
end

--- Connect a consumer to a signal.
-- If a producer is registered and this is the first consumer, the producer
-- is started automatically. Returns a disconnect function for cleanup.
--
-- @tparam string name Signal name (e.g. "data::cpu")
-- @tparam function fn Callback receiving (data)
-- @treturn function Disconnect function — call to unsubscribe
function broker.connect_signal(name, fn)
	assert(type(name) == "string", "signal name must be a string")
	assert(type(fn) == "function", "callback must be a function")

	local sig = get_signal(name)
	local was_empty = next(sig.consumers) == nil
	sig.consumers[fn] = true

	-- Auto-start producer on first consumer
	if was_empty and sig.producer and sig.producer.start then
		sig.producer:start()
	end

	-- Deliver cached value to new consumer (late join)
	local val = broker._values[name]
	if val ~= nil then
		local ok, err = pcall(fn, val)
		if not ok then
			io.stderr:write(string.format("[broker] consumer error on connect (%s): %s\n", name, err))
		end
	end

	-- Return disconnect function
	return function()
		broker.disconnect_signal(name, fn)
	end
end

--- Disconnect a consumer from a signal.
-- If this was the last consumer, the producer is stopped.
--
-- @tparam string name Signal name
-- @tparam function fn The callback to disconnect
function broker.disconnect_signal(name, fn)
	local sig = broker._signals[name]
	if not sig then return end

	sig.consumers[fn] = nil

	-- Auto-stop producer when no consumers remain
	if next(sig.consumers) == nil and sig.producer and sig.producer.stop then
		sig.producer:stop()
	end
end

--- Emit a signal to all consumers.
-- Each consumer is called in a pcall — one consumer's error doesn't affect others.
-- Nil data is silently ignored (no emit, no cache update).
--
-- @tparam string name Signal name
-- @param data The data to broadcast (table, number, string, etc.)
function broker.emit_signal(name, data)
	if data == nil then return end

	broker._values[name] = data

	local sig = broker._signals[name]
	if not sig then return end

	for fn in pairs(sig.consumers) do
		local ok, err = pcall(fn, data)
		if not ok then
			io.stderr:write(string.format("[broker] consumer error (%s): %s\n", name, err))
		end
	end
end

--- Register a producer (service) for a signal.
-- If consumers are already connected (late registration), the producer
-- is started immediately.
--
-- @tparam string name Signal name
-- @param producer Service object with :start() and :stop() methods
function broker.register_producer(name, producer)
	local sig = get_signal(name)
	sig.producer = producer

	-- Retroactive start if consumers already waiting
	if next(sig.consumers) ~= nil and producer.start then
		producer:start()
	end
end

--- Get the last cached value for a signal.
--
-- @tparam string name Signal name
-- @return The last emitted value, or nil
function broker.get_value(name)
	return broker._values[name]
end

--- Reset broker state (for testing).
function broker._reset()
	-- Stop all producers
	for _, sig in pairs(broker._signals) do
		if sig.producer and sig.producer.stop then
			sig.producer:stop()
		end
	end
	broker._values = {}
	broker._signals = {}
end

return broker
