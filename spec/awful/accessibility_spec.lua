describe('awful.accessibility', function()
    local a11y, saved, signals, timers, theme, scale, transitions
    local function emit(name, ...)
        local handlers = {}
        for _, fn in ipairs(signals[name] or {}) do handlers[#handlers + 1] = fn end
        for _, fn in ipairs(handlers) do fn(...) end
    end
    before_each(function()
        saved = {awesome = _G.awesome, root = _G.root, mouse = _G.mouse,
            timer = package.loaded['gears.timer'], beautiful = package.loaded.beautiful,
            accessibility = package.loaded['awful.accessibility']}
        signals, timers, theme, scale, transitions = {}, {}, {}, 1, {}
        _G.awesome = {
            connect_signal = function(name, fn)
                signals[name] = signals[name] or {}
                table.insert(signals[name], fn)
            end,
            disconnect_signal = function(name, fn)
                for i, handler in ipairs(signals[name] or {}) do
                    if handler == fn then table.remove(signals[name], i); return end
                end
            end,
        }
        _G.root = {_cursor_magnify = function(value, duration)
            if value then transitions[#transitions + 1] = {value, duration} end
            scale = value or scale
            return scale
        end}
        _G.mouse = {coords = function() return {x = 0, y = 0} end}
        package.loaded.beautiful = theme
        package.loaded['gears.timer'] = setmetatable({}, {__call = function(_, args)
            local t = {started = args.autostart, callback = args.callback, restarts = 0}
            function t:stop() self.started = false end
            function t:again() self.started = true; self.restarts = self.restarts + 1 end
            function t:fire() self.started = false; self.callback() end
            timers[#timers + 1] = t
            return t
        end})
        package.loaded['awful.accessibility'] = nil
        a11y = require('awful.accessibility')
    end)
    after_each(function()
        emit('exit')
        _G.awesome, _G.root, _G.mouse = saved.awesome, saved.root, saved.mouse
        package.loaded['gears.timer'], package.loaded.beautiful = saved.timer, saved.beautiful
        package.loaded['awful.accessibility'] = saved.accessibility
    end)
    local function locator(args)
        args = args or {}
        args.cursor_finder_effect = 'magnify'
        args.cursor_finder_cooldown = 0
        return a11y(args)
    end
    it('stays idle without an enabled motion observer', function()
        locator()
        assert.equals(0, #timers)
        assert.equals(0, #(signals['_accessibility::motion'] or {}))
    end)
    it('preserves false overrides and restores theme fallback with nil', function()
        theme.accessibility_cursor_finder_enabled = true
        local a = locator {cursor_finder_enabled = false}
        a:find_cursor()
        assert.equals(1, scale)
        a.cursor_finder_enabled = nil
        a:find_cursor()
        assert.equals(3, scale)
    end)
    it('transfers shake observation and notifies the displaced instance', function()
        local a = locator {cursor_finder_shake_enabled = true}
        local notified
        a:connect_signal('property::cursor_finder_shake_enabled', function(_, enabled) notified = enabled end)
        local b = locator {cursor_finder_shake_enabled = true}
        assert.is_false(a.cursor_finder_shake_enabled)
        assert.is_false(notified)
        assert.equals(1, #signals['_accessibility::motion'])
        b.cursor_finder_enabled = false
        assert.equals(0, #signals['_accessibility::motion'])
        b.cursor_finder_enabled = true
        assert.equals(1, #signals['_accessibility::motion'])
    end)
    it('ignores straight motion and small jitter and detects large reversals', function()
        locator {cursor_finder_shake_enabled = true}
        for x = 1, 100 do emit('_accessibility::motion', x, 0) end
        assert.equals(1, scale)
        for _ = 1, 30 do emit('_accessibility::motion', 99, 0); emit('_accessibility::motion', 100, 0) end
        assert.equals(1, scale)
        for _ = 1, 8 do emit('_accessibility::motion', 0, 0); emit('_accessibility::motion', 120, 0) end
        assert.is_true(scale >= 3)
    end)
    it('extends inflation, caps growth, and cancels stale deflation timers', function()
        local a = locator()
        a:find_cursor()
        local old = timers[#timers]
        a:find_cursor()
        assert.is_false(old.started)
        assert.equals(4, scale)
        a:find_cursor()
        assert.equals(4, scale)
        timers[#timers]:fire()
        assert.equals(1, scale)
        local finish = timers[#timers]
        a:find_cursor()
        assert.is_false(finish.started)
        assert.equals(3, scale)
    end)
    it('ends the previous owner once without letting its stop affect the new one', function()
        local a, b = locator(), locator {cursor_finder_magnification = 2}
        local ended = 0
        a:connect_signal('cursor_finder::end', function() ended = ended + 1 end)
        a:find_cursor()
        b:find_cursor()
        assert.equals(1, ended)
        assert.equals(2, scale)
        a:stop_cursor_finder()
        assert.equals(1, ended)
        assert.equals(2, scale)
    end)
    it('restores the cursor and removes subscriptions on repeated exit', function()
        local a = locator {cursor_finder_shake_enabled = true}
        a:find_cursor()
        emit('exit')
        emit('exit')
        assert.equals(1, scale)
        assert.equals(0, #signals['_accessibility::motion'])
        for _, t in ipairs(timers) do assert.is_false(t.started) end
    end)
    it('gives activation from an end handler precedence over the interrupted caller', function()
        local a, b, c = locator(), locator {cursor_finder_magnification = 4},
            locator {cursor_finder_magnification = 2}
        local starts = 0
        b:connect_signal('cursor_finder::start', function() starts = starts + 1 end)
        a:connect_signal('cursor_finder::end', function() c:find_cursor() end)
        a:find_cursor()
        local stale = timers[#timers]
        b:find_cursor()
        assert.equals(2, scale)
        assert.equals(0, starts)
        assert.is_false(stale.started)
        stale:fire()
        assert.equals(2, scale)
        b:stop_cursor_finder()
        assert.equals(2, scale)
        c:stop_cursor_finder()
        assert.equals(1, scale)
        for _, t in ipairs(timers) do assert.is_false(t.started) end
    end)
    it('ignores stale deflation and completion callbacks after reactivation', function()
        local a = locator()
        a:find_cursor()
        local deflate = timers[#timers]
        deflate:fire()
        local finish = timers[#timers]
        a:find_cursor()
        deflate:fire()
        finish:fire()
        assert.equals(3, scale)
        assert.is_true(a._private.magnifying)
        a:stop_cursor_finder()
    end)
    it('honours disabling the requested locator from the previous end handler', function()
        local a, b = locator(), locator()
        a:connect_signal('cursor_finder::end', function() b.cursor_finder_enabled = false end)
        a:find_cursor()
        b:find_cursor()
        assert.equals(1, scale)
        for _, t in ipairs(timers) do assert.is_false(t.started) end
    end)
    it('does not start another locator from an exit callback', function()
        local a, b = locator(), locator()
        a:connect_signal('cursor_finder::end', function() b:find_cursor() end)
        a:find_cursor()
        emit('exit')
        assert.equals(1, scale)
        for _, t in ipairs(timers) do assert.is_false(t.started) end
    end)
    it('holds unanimated magnification and restores it without interpolation', function()
        theme.accessibility_cursor_finder_animated = true
        local a = locator {cursor_finder_animated = false}
        a:find_cursor()
        assert.same({3, 0}, transitions[#transitions])
        local old = timers[#timers]
        a:find_cursor()
        assert.is_false(old.started)
        assert.same({4, 0}, transitions[#transitions])
        timers[#timers]:fire()
        assert.same({1, 0}, transitions[#transitions])
        a.cursor_finder_animated = nil
        assert.is_true(a.cursor_finder_animated)
        a:find_cursor()
        assert.same({3, .2}, transitions[#transitions])
        a.cursor_finder_animated = false
        assert.equals(1, scale)
        for _, t in ipairs(timers) do assert.is_false(t.started) end
    end)

end)
